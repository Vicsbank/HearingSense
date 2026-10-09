import pandas as pd  # 导入pandas库，用于数据处理和CSV文件操作
import os  # 导入os库，用于与操作系统交互，如路径操作、列出文件等
from tqdm import tqdm # 导入tqdm库，用于显示进度条
import numpy as np # 导入numpy库，用于数值计算
import config

# 定义训练数据CSV文件的路径
train_csv = config.EMOTIFY_ANNOTATIONS
# 定义包含音频文件类型子文件夹的基础目录路径
base_dir = config.EMOTIFY_AUDIO_DIR
# 定义不同音乐流派的ID偏移量，用于生成新的、全局唯一的track_id
genre_offsets = {"classical": 0, "rock": 100, "electronic": 200, "pop": 300}

# 创建一个空列表，用于存储文件名映射信息
filename_mapping = []

# 遍历genre_offsets字典中的每个音乐流派及其对应的偏移量
for genre, offset in genre_offsets.items():
    # 构建当前流派的文件夹路径
    genre_path = os.path.join(base_dir, genre)

    # 检查当前流派的文件夹是否存在
    if not os.path.exists(genre_path):
        # 如果文件夹不存在，打印警告信息并跳过当前流派
        print(f"⚠️ Genre folder not found: {genre_path}")
        continue

    # 遍历当前流派文件夹中的所有文件
    for filename in os.listdir(genre_path):
        # 检查文件名是否以 ".mp3" 结尾
        if filename.endswith(".mp3"):
            try:
                # 尝试从文件名中提取原始的track_id（去除扩展名并转换为整数）
                # os.path.splitext(filename) 会将文件名分割为 (文件名主体, .扩展名)
                old_track_id = int(os.path.splitext(filename)[0]) 
                # 根据原始track_id和流派偏移量计算新的track_id
                new_track_id = old_track_id + offset 

                # 将映射信息作为一个字典追加到filename_mapping列表中
                filename_mapping.append({
                    "genre": genre,  # 当前流派
                    "original_filename": filename,  # 原始文件名
                    "original_path": f"{genre}/{filename}",  # 相对于 EMOTIFY_AUDIO_DIR 的路径
                    "new_track_id": new_track_id,  # 新的、全局唯一的track_id
                    "new_filename": f"{new_track_id}.mp3"  # 基于新track_id生成的新文件名
                })

            except ValueError:
                # 如果文件名无法转换为整数（例如文件名不是纯数字），打印警告并跳过该文件
                print(f"⚠️ Skipping invalid filename: {filename}")

# 将收集到的文件名映射信息列表转换为Pandas DataFrame
filename_map_df = pd.DataFrame(filename_mapping)
# 从CSV文件读取情感数据到Pandas DataFrame
emotion_data = pd.read_csv(train_csv)
# 从情感数据中提取所有不重复的 "track id"，并存储为一个集合，用于快速查找
relevant_track_ids = set(emotion_data["track id"])
# 筛选文件名映射DataFrame，只保留那些新的track_id存在于情感数据中的记录
filtered_map_df = filename_map_df[filename_map_df["new_track_id"].isin(relevant_track_ids)]
# 定义情感数据中与情感维度相关的列名列表 (注意列名前可能存在的空格)
emotion_cols = [
    ' amazement', ' solemnity', ' tenderness', ' nostalgia',
    ' calmness', ' power', ' joyful_activation', ' tension', ' sadness'
]

# 按 'track id' 分组，计算每个track_id对应的情感维度列的平均值
aggregated_emotions = emotion_data.groupby('track id')[emotion_cols].mean().reset_index()
# 按 'track id' 分组，获取每个track_id对应的第一个 ' genre' 值 (假设每个track_id只有一个genre)
genre_map = emotion_data.groupby('track id')[' genre'].first()
# 将聚合后的情感数据与对应的genre信息合并（基于共同的 'track id' 列）
aggregated_emotions = aggregated_emotions.merge(genre_map, on='track id')

# 假设 aggregated_emotions 和 filtered_map_df 已经如您脚本中那样定义好了

print("\n--- Merging aggregated_emotions with filtered_map_df ---")

# 使用 pd.merge 连接两个DataFrame
# left_on='track id' 表示使用 aggregated_emotions DataFrame 中的 'track id' 列作为左连接键
# right_on='new_track_id' 表示使用 filtered_map_df DataFrame 中的 'new_track_id' 列作为右连接键
# how='inner' 表示只保留两个DataFrame中连接键都存在的行
merged_df = pd.merge(
    aggregated_emotions,
    filtered_map_df,
    left_on='track id',
    right_on='new_track_id',
    how='inner'  # 您也可以根据需求选择 'left', 'right', 或 'outer'
)

# 'genre' 与 ' genre' 重复，只保留原始标注里的 ' genre'
merged_df = merged_df.drop(columns=['genre'])
print(merged_df)
merged_df.to_csv(config.train_csv, index=False)