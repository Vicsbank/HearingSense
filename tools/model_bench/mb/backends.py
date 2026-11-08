"""One interface for every model: generate(instructions, prompt, limit, schema) -> Reply.

MLXBackend runs an open-weight checkpoint in this process with mlx-lm. AppleBackend talks to the
Swift bridge (apple_bridge), which calls FoundationModels' SystemLanguageModel.default. The two are
measured differently where they must be; see docs/testing/MAC_MODEL_BENCHMARK.md.
"""
from __future__ import annotations

import copy
import json
import resource
import subprocess
import time
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass
class Reply:
    text: str = ""
    seconds: float = 0.0            # request sent -> full reply
    first_seconds: float | None = None   # request sent -> first piece of the reply
    input_tokens: int | None = None      # tokens processed for this request (after any cached prefix)
    cached_tokens: int | None = None
    output_tokens: int | None = None
    prefill_tps: float | None = None
    decode_tps: float | None = None
    finish: str | None = None
    error: str | None = None

    def as_dict(self) -> dict:
        return asdict(self)


class MLXBackend:
    kind = "mlx"

    def __init__(self, repo: str, prefix_cache: bool = True, thinking: bool = False):
        self.repo, self.prefix_cache, self.thinking = repo, prefix_cache, thinking
        self.model = self.tokenizer = None
        self._prefix: dict[str, tuple[list[int], object]] = {}
        self.info: dict = {}

    def load(self) -> dict:
        import mlx.core as mx
        import mlx_lm
        import psutil

        mx.reset_peak_memory()
        started = time.perf_counter()
        self.model, self.tokenizer = mlx_lm.load(self.repo)
        mx.eval(self.model.parameters())
        seconds = time.perf_counter() - started
        template = getattr(self.tokenizer, "chat_template", None) or ""
        self._thinking_switch = "enable_thinking" in template
        self.info = {
            "repo": self.repo, "runtime": f"mlx-lm {mlx_lm.__version__}, mlx {mx.__version__}",
            "load_seconds": seconds, "mlx_active_gb_after_load": mx.get_active_memory() / 1e9,
            "rss_gb_after_load": psutil.Process().memory_info().rss / 1e9,
            "template_has_thinking_switch": self._thinking_switch, "thinking": self.thinking,
            "prefix_cache": self.prefix_cache, "sampling": "greedy (temperature 0)",
        }
        return self.info

    def tokens(self, instructions: str, prompt: str) -> list[int]:
        messages = [{"role": "system", "content": instructions}, {"role": "user", "content": prompt}]
        extra = {"enable_thinking": self.thinking} if self._thinking_switch else {}
        return list(self.tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=True, **extra))

    def rendered(self, instructions: str, prompt: str) -> str:
        return self.tokenizer.decode(self.tokens(instructions, prompt))

    def _cached_prefix(self, instructions: str, tokens: list[int]):
        """The instructions are the same for every request; their keys and values are computed once
        (what a deployed app would do), and each request continues from a copy."""
        import mlx.core as mx
        from mlx_lm.models.cache import make_prompt_cache

        if instructions not in self._prefix:
            other = self.tokens(instructions, "x")
            shared = 0
            while shared < min(len(tokens), len(other)) and tokens[shared] == other[shared]:
                shared += 1
            shared = max(0, shared - 1)   # keep at least the last shared token out of the cache
            cache = make_prompt_cache(self.model)
            if shared:
                self.model(mx.array(tokens[:shared])[None], cache=cache)
                mx.eval([c.state for c in cache])
            self._prefix[instructions] = (tokens[:shared], cache)
        prefix, cache = self._prefix[instructions]
        if tokens[:len(prefix)] != prefix:
            return [], None
        return prefix, copy.deepcopy(cache)

    def generate(self, instructions: str, prompt: str, limit: int, schema: dict | None = None) -> Reply:
        import mlx_lm
        from mlx_lm.sample_utils import make_sampler

        reply = Reply()
        try:
            tokens = self.tokens(instructions, prompt)
            started = time.perf_counter()
            cache, prefix = None, []
            if self.prefix_cache:
                prefix, cache = self._cached_prefix(instructions, tokens)
                started = time.perf_counter()   # building the shared prefix once is not this request's time
            pieces, last = [], None
            for part in mlx_lm.stream_generate(self.model, self.tokenizer, prompt=tokens[len(prefix):], max_tokens=limit,
                                               sampler=make_sampler(temp=0.0), prompt_cache=cache):
                if reply.first_seconds is None:
                    reply.first_seconds = time.perf_counter() - started
                pieces.append(part.text)
                last = part
            reply.seconds = time.perf_counter() - started
            reply.text = "".join(pieces)
            if last is not None:
                reply.input_tokens, reply.cached_tokens = last.prompt_tokens, len(prefix)
                reply.output_tokens, reply.finish = last.generation_tokens, last.finish_reason
                reply.prefill_tps, reply.decode_tps = last.prompt_tps, last.generation_tps
        except Exception as error:  # recorded, never dropped
            reply.error = f"{type(error).__name__}: {error}"[:300]
        return reply

    def memory(self) -> dict:
        import mlx.core as mx
        import psutil

        return {"mlx_peak_gb": mx.get_peak_memory() / 1e9, "mlx_active_gb": mx.get_active_memory() / 1e9,
                "rss_gb": psutil.Process().memory_info().rss / 1e9,
                "max_rss_gb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9}

    def close(self) -> None:
        self.model = self.tokenizer = None
        self._prefix.clear()


class AppleBackend:
    """SystemLanguageModel.default through the Swift bridge. mode "guided": the reply is constrained
    to the schema by the framework (how Hearing Sense uses the model). mode "text": plain text, the
    same free-form request the open-weight models get."""
    kind = "apple"

    def __init__(self, bridge: Path, mode: str = "guided", prewarm: bool = True):
        self.bridge, self.mode, self.prewarm = bridge, mode, prewarm
        self.process = None
        self.info: dict = {}

    def _ask(self, request: dict) -> dict:
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("the Apple bridge ended: " + (self.process.stderr.read() or "")[:300])
        return json.loads(line)

    def load(self) -> dict:
        started = time.perf_counter()
        self.process = subprocess.Popen([str(self.bridge)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)
        self.info = self._ask({"command": "info"})
        self.info.update({"bridge_start_seconds": time.perf_counter() - started, "mode": self.mode,
                          "prewarm": self.prewarm, "sampling": "greedy",
                          "runtime": "FoundationModels, SystemLanguageModel.default"})
        return self.info

    def generate(self, instructions: str, prompt: str, limit: int, schema: dict | None = None) -> Reply:
        request = {"command": "generate", "instructions": instructions, "prompt": prompt, "limit": limit,
                   "prewarm": self.prewarm, "schema": schema if self.mode == "guided" else None}
        started = time.perf_counter()
        try:
            answer = self._ask(request)
        except Exception as error:
            return Reply(error=f"{type(error).__name__}: {error}"[:300], seconds=time.perf_counter() - started)
        return Reply(text=answer.get("text", ""), seconds=answer.get("seconds", 0.0), first_seconds=answer.get("first_seconds"),
                     input_tokens=answer.get("input_tokens"), cached_tokens=answer.get("cached_tokens"),
                     output_tokens=answer.get("output_tokens"), error=answer.get("error"))

    def rendered(self, instructions: str, prompt: str) -> str:
        return "[instructions]\n" + instructions + "\n[prompt]\n" + prompt

    def memory(self) -> dict:
        return {"note": "the model runs in a system service; its memory is not visible to this process"}

    def close(self) -> None:
        if self.process:
            self.process.stdin.close()
            self.process.wait(timeout=20)
            self.process = None
