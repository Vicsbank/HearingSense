import torch.nn as nn
import timm

class EfficientNetModel(nn.Module):
    def __init__(self, num_classes=9, pretrained=True):
        super(EfficientNetModel, self).__init__()

        # 加载预训练的EfficientNet-B0模型
        self.backbone = timm.create_model(
            'efficientnet_b0.ra_in1k',
            pretrained=pretrained,
            num_classes=0,  # 移除分类头，只保留特征提取部分
            global_pool='avg'  # 使用全局平均池化
        )

        # 获取backbone输出的特征维度
        # EfficientNet-B0的特征维度是1280
        feature_dim = self.backbone.num_features

        # 自定义分类头
        self.classifier = nn.Sequential(
            nn.Dropout(p=0.5),
            nn.Linear(feature_dim, 256),
            nn.ReLU(),
            nn.Dropout(p=0.5),
            nn.Linear(256, num_classes)
        )

    def forward(self, x):
        # 如果输入是单通道，需要转换为3通道（RGB）
        if x.shape[1] == 1:
            x = x.repeat(1, 3, 1, 1)

        # 通过backbone提取特征
        features = self.backbone(x)

        # 通过分类头得到最终输出
        output = self.classifier(features)

        return output
