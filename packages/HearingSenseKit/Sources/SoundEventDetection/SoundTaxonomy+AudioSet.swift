import HearingSenseDomain

extension SoundModelID {
    /// Google YAMNet (MobileNet-v1, AudioSet, 521 classes), converted to Core ML.
    public static let yamnet = SoundModelID(rawValue: "google.yamnet.audioset521")
    /// EfficientAT mn10_as (MobileNetV3, AudioSet, 527 classes), converted to Core ML.
    public static let efficientATMN10 = SoundModelID(rawValue: "efficientat.mn10_as.audioset527")
    /// EfficientAT dymn04_as (dynamic MobileNet, AudioSet, 527 classes), converted to Core ML.
    public static let efficientATDyMN04 = SoundModelID(rawValue: "efficientat.dymn04_as.audioset527")
}

extension SoundTaxonomy {
    /// The same kinds, categories and temporal profiles as `appleV1`, fed by AudioSet class names
    /// (YAMNet, EfficientAT). Labels are the models' own display names, unchanged
    /// ("Vehicle horn, car horn, honking"); see `AudioSetLabelTable` for what is and is not mapped.
    /// Kinds without any AudioSet class keep an empty label list and can never fire.
    public static func audioSet(model: SoundModelID) -> SoundTaxonomy {
        var names: [SoundLabel: String] = [:]
        let definitions = appleV1.definitions.map { definition -> SoundKindDefinition in
            let entry = AudioSetLabelTable.byKind[definition.kind.id]
            let labels = ((entry?.exact ?? []) + (entry?.within ?? [])).map { SoundLabel($0) }
            for label in labels { names[label] = label.rawValue }
            return SoundKindDefinition(kind: definition.kind, profile: definition.profile, labels: labels,
                                       producesEvents: definition.producesEvents)
        }
        return SoundTaxonomy(model: model, definitions: definitions, silenceLabel: "Silence", displayNames: names)
    }

    /// AudioSet classes that mean a human voice making music (the counterpart of the Apple
    /// labels in `SpeechActivationPolicy.vocalMusicLabels`).
    public static let audioSetVocalMusicLabels: Set<SoundLabel> = [
        "Singing", "Choir", "Rapping", "Humming", "Yodeling", "Chant", "Mantra", "Male singing", "Female singing",
        "Child singing", "Synthetic singing",
    ]
}

extension SoundModelID {
    /// Apple's classifier while the app is in the foreground, a CPU-only Core ML model otherwise.
    /// Individual frames and events carry the model that actually produced them.
    public static func hybrid(background: SoundModelID) -> SoundModelID {
        SoundModelID(rawValue: "hybrid(\(SoundModelID.appleSoundClassifierV1.rawValue) | \(background.rawValue))")
    }
}

extension DetectionPolicy {
    /// `standard` for a pipeline that may receive Apple or AudioSet labels (hybrid backend).
    public static let standardHybrid: DetectionPolicy = {
        var policy = DetectionPolicy.standard
        policy.suppressions += DetectionPolicy.standardAudioSet.suppressions
        return policy
    }()
}

extension DetectionPolicy {
    /// `standard` with its label-specific rule expressed in AudioSet names. Every threshold is
    /// the one chosen for Apple's classifier: scores of different models are not comparable, so
    /// these values are a starting point, not a calibration
    /// (docs/research/BACKGROUND_MODEL_BENCHMARK.md).
    public static let standardAudioSet: DetectionPolicy = {
        var policy = DetectionPolicy.standard
        policy.suppressions = [LabelSuppression(label: "Foghorn", competingKind: "music", minimumCompetingScore: 0.5)]
        return policy
    }()
}
