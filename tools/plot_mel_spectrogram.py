import librosa
import librosa.display
import matplotlib.pyplot as plt
import numpy as np

def audio_to_mel_spectrogram(mp3_path, duration=60):
    """
    Convert the first 60 seconds of an MP3 file to a Mel spectrogram and display it.
    
    Args:
        mp3_path (str): Path to the MP3 file.
        duration (int): Duration in seconds to process (default 60).
    """
    try:
        # Load the MP3 file
        y, sr = librosa.load(mp3_path, sr=None)  # y is the audio time series, sr is the sample rate
        
        # Trim to the first 60 seconds
        samples_to_take = duration * sr
        if len(y) > samples_to_take:
            y = y[:samples_to_take]
        else:
            print(f"Warning: Audio is shorter than {duration} seconds ({len(y)/sr:.2f} seconds). Using full length.")
        
        # Compute the Mel spectrogram
        mel_spec = librosa.feature.melspectrogram(y=y, sr=sr, n_mels=128, n_fft=2048, hop_length=512)
        mel_spec_db = librosa.power_to_db(mel_spec, ref=np.max)  # Convert to decibels
        
        # Create the plot
        plt.figure(figsize=(12, 4))
        librosa.display.specshow(mel_spec_db, sr=sr, hop_length=512, x_axis='time', y_axis='mel')
        plt.colorbar(format='%+2.0f dB')
        plt.title(f'Mel Spectrogram')
        plt.xlabel('Time (s)')
        plt.ylabel('Mel Frequency')
        
        # Add some styling
        plt.tight_layout()
        
        # Display the plot
        plt.show()
        
        # Optionally return the Mel spectrogram for further use
        return mel_spec_db

    except FileNotFoundError:
        print(f"Error: The file {mp3_path} was not found.")
    except Exception as e:
        print(f"Error: An unexpected error occurred: {e}")

# Example usage
if __name__ == "__main__":
    import sys
    if len(sys.argv) != 2:
        print('Usage: python tools/plot_mel_spectrogram.py "data/samples/Shattered Roads.mp3"')
        sys.exit(1)
    mel_spectrogram = audio_to_mel_spectrogram(sys.argv[1])
