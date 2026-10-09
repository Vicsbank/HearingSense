import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader
from torch.optim import lr_scheduler

import pandas as pd
import numpy as np
import os
import random
import gc
from tqdm.auto import tqdm
from itertools import cycle

from sklearn.model_selection import train_test_split
from sklearn.metrics import (roc_auc_score, accuracy_score, precision_score, 
                             recall_score, confusion_matrix, roc_curve, auc as calc_auc)
from sklearn.preprocessing import label_binarize


import matplotlib.pyplot as plt
import seaborn as sns

from emotion_dataset import MusicEmoDataset
from emotion_model import EfficientNetModel
import config as cfg

RESULTS_EMOTION = cfg.RESULTS_DIR / 'emotion'

# --- MODIFICATION: 修改 plot_history 函数以包含 Precision 和 Recall ---
def plot_history(history, save_path=RESULTS_EMOTION):
    """
    绘制训练过程中的 loss, accuracy, AUC, precision 和 recall 曲线图
    """
    epochs = range(1, len(history['train_loss']) + 1)

    # 1. 绘制 Loss 和 Accuracy 曲线
    plt.figure(figsize=(15, 5))
    plt.subplot(1, 2, 1)
    plt.plot(epochs, history['train_loss'], 'bo-', label='Training Loss')
    plt.plot(epochs, history['val_loss'], 'ro-', label='Validation Loss')
    plt.title('Training and Validation Loss')
    plt.xlabel('Epochs')
    plt.ylabel('Loss')
    plt.legend()
    plt.grid(True)
    
    plt.subplot(1, 2, 2)
    plt.plot(epochs, history['train_acc'], 'bo-', label='Training Accuracy')
    plt.plot(epochs, history['val_acc'], 'ro-', label='Validation Accuracy')
    plt.title('Training and Validation Accuracy')
    plt.xlabel('Epochs')
    plt.ylabel('Accuracy')
    plt.legend()
    plt.grid(True)
    
    plt.tight_layout()
    plt.savefig(os.path.join(save_path, 'loss_accuracy_curves.png'))
    plt.show()

    # 2. 绘制 AUC, Precision 和 Recall 曲线
    plt.figure(figsize=(20, 5))
    plt.subplot(1, 3, 1)
    plt.plot(epochs, history['train_auc'], 'go-', label='Training AUC')
    plt.plot(epochs, history['val_auc'], 'yo-', label='Validation AUC')
    plt.title('Training and Validation AUC')
    plt.xlabel('Epochs')
    plt.ylabel('AUC')
    plt.legend()
    plt.grid(True)

    plt.subplot(1, 3, 2)
    plt.plot(epochs, history['train_precision'], 'co-', label='Training Precision')
    plt.plot(epochs, history['val_precision'], 'mo-', label='Validation Precision')
    plt.title('Training and Validation Precision')
    plt.xlabel('Epochs')
    plt.ylabel('Precision')
    plt.legend()
    plt.grid(True)

    plt.subplot(1, 3, 3)
    plt.plot(epochs, history['train_recall'], 'ko-', label='Training Recall')
    plt.plot(epochs, history['val_recall'], 'o-', color='orange', label='Validation Recall')
    plt.title('Training and Validation Recall')
    plt.xlabel('Epochs')
    plt.ylabel('Recall')
    plt.legend()
    plt.grid(True)

    plt.tight_layout()
    plt.savefig(os.path.join(save_path, 'metrics_curves.png'))
    plt.show()

def plot_confusion_matrix(y_true, y_pred_classes, class_names, save_path=RESULTS_EMOTION):
    """
    绘制混淆矩阵
    """
    cm = confusion_matrix(y_true, y_pred_classes)
    plt.figure(figsize=(12, 10))
    sns.heatmap(cm, annot=True, fmt='d', cmap='Blues', 
                xticklabels=class_names, yticklabels=class_names)
    plt.title('Confusion Matrix', fontsize=16)
    plt.ylabel('True Label', fontsize=12)
    plt.xlabel('Predicted Label', fontsize=12)
    plt.xticks(rotation=45)
    plt.yticks(rotation=0)
    plt.tight_layout()
    plt.savefig(os.path.join(save_path, 'confusion_matrix.png'))
    plt.show()

# --- NEW: 新增 ROC 曲线绘制函数 ---
def plot_roc_curves(y_true, y_prob, class_names, save_path=RESULTS_EMOTION):
    """
    为多分类任务绘制ROC曲线
    """
    n_classes = len(class_names)
    # 将真实标签二值化
    y_true_bin = label_binarize(y_true, classes=range(n_classes))

    # 为每个类别计算ROC曲线和AUC
    fpr = dict()
    tpr = dict()
    roc_auc = dict()
    for i in range(n_classes):
        fpr[i], tpr[i], _ = roc_curve(y_true_bin[:, i], y_prob[:, i])
        roc_auc[i] = calc_auc(fpr[i], tpr[i])

    # 计算宏平均ROC曲线
    all_fpr = np.unique(np.concatenate([fpr[i] for i in range(n_classes)]))
    mean_tpr = np.zeros_like(all_fpr)
    for i in range(n_classes):
        mean_tpr += np.interp(all_fpr, fpr[i], tpr[i])
    mean_tpr /= n_classes
    fpr["macro"] = all_fpr
    tpr["macro"] = mean_tpr
    roc_auc["macro"] = calc_auc(fpr["macro"], tpr["macro"])

    # 绘制所有类别的ROC曲线
    plt.figure(figsize=(12, 10))
    colors = cycle(['aqua', 'darkorange', 'cornflowerblue', 'green', 'red', 'purple', 'brown', 'pink', 'gray', 'olive', 'cyan'])
    
    for i, color in zip(range(n_classes), colors):
        plt.plot(fpr[i], tpr[i], color=color, lw=2,
                 label=f'ROC curve of class {class_names[i]} (area = {roc_auc[i]:.2f})')
        
    # 绘制宏平均ROC曲线
    plt.plot(fpr["macro"], tpr["macro"],
             label=f'macro-average ROC curve (area = {roc_auc["macro"]:.2f})',
             color='navy', linestyle=':', linewidth=4)

    plt.plot([0, 1], [0, 1], 'k--', lw=2)
    plt.xlim([0.0, 1.0])
    plt.ylim([0.0, 1.05])
    plt.xlabel('False Positive Rate', fontsize=12)
    plt.ylabel('True Positive Rate', fontsize=12)
    plt.title('Multi-class Receiver Operating Characteristic (ROC) Curve', fontsize=16)
    plt.legend(loc="lower right")
    plt.grid(True)
    plt.savefig(os.path.join(save_path, 'roc_curves.png'))
    plt.show()


def set_seed(seed=42):
    random.seed(seed)
    os.environ["PYTHONHASHSEED"] = str(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False

set_seed(cfg.seed)

# --- MODIFICATION: 修改 validate 函数以返回概率 ---
def validate(model, loader, criterion, device):
    model.eval()
    losses = []
    all_targets_list = []
    all_outputs_prob_list = []
    all_preds_class_list = []

    with torch.no_grad():
        for batch in tqdm(loader, desc="Validation"):
            inputs = batch['audios'].to(device)
            targets = batch['labels'].to(device) 
            
            outputs = model(inputs)
            loss = criterion(outputs, targets)
            
            probs = torch.softmax(outputs, dim=1)
            preds_class = torch.argmax(probs, dim=1)

            all_outputs_prob_list.append(probs.cpu())
            all_preds_class_list.append(preds_class.cpu())
            all_targets_list.append(targets.cpu())
            losses.append(loss.item())
            
    all_outputs_prob = torch.cat(all_outputs_prob_list).numpy()
    all_preds_class = torch.cat(all_preds_class_list).numpy()
    all_targets = torch.cat(all_targets_list).numpy()
    
    # 兼容 one-hot 和 index 两种标签格式
    if all_targets.ndim > 1:
        all_targets_indices = np.argmax(all_targets, axis=1)
    else:
        all_targets_indices = all_targets

    avg_loss = np.mean(losses)
    num_classes = all_outputs_prob.shape[1]
    all_possible_labels = np.arange(num_classes)
    
    auc = roc_auc_score(all_targets_indices, all_outputs_prob, multi_class='ovr', average='macro', labels=all_possible_labels)
    accuracy = accuracy_score(all_targets_indices, all_preds_class)
    precision = precision_score(all_targets_indices, all_preds_class, average='macro', zero_division=0)
    recall = recall_score(all_targets_indices, all_preds_class, average='macro', zero_division=0)

    # 返回原始标签、预测类别和预测概率
    return avg_loss, auc, accuracy, precision, recall, all_targets, all_preds_class, all_outputs_prob

# --- MODIFICATION: 修改 train_one_epoch 以返回更多指标 ---
def train_one_epoch(model, loader, optimizer, criterion, device, scheduler=None):
    model.train()
    losses = []
    all_targets_list = []
    all_outputs_list = []
    
    pbar = tqdm(enumerate(loader), total=len(loader), desc="Training")
    
    for step, batch in pbar:
        inputs = batch['audios'].to(device)
        targets = batch['labels'].to(device)

        optimizer.zero_grad()
        outputs = model(inputs)
        loss = criterion(outputs, targets)
        loss.backward()
        optimizer.step()
        
        if scheduler is not None and isinstance(scheduler, lr_scheduler.OneCycleLR):
            scheduler.step()
            
        all_outputs_list.append(outputs.detach().cpu())
        all_targets_list.append(targets.detach().cpu())
        losses.append(loss.item())
        
        pbar.set_postfix({
            'train_loss': np.mean(losses[-10:]),
            'lr': optimizer.param_groups[0]['lr']
        })
        
    all_outputs = torch.cat(all_outputs_list).numpy()
    all_targets = torch.cat(all_targets_list).numpy()

    if all_targets.ndim > 1:
        all_targets_indices = np.argmax(all_targets, axis=1)
    else:
        all_targets_indices = all_targets
    
    avg_loss = np.mean(losses)
    probs = torch.softmax(torch.from_numpy(all_outputs), dim=1).numpy()
    preds_class = np.argmax(probs, axis=1)
    num_classes = probs.shape[1]
    all_possible_labels = np.arange(num_classes)
    
    auc = roc_auc_score(all_targets_indices, probs, multi_class='ovr', average='macro', labels=all_possible_labels)
    accuracy = accuracy_score(all_targets_indices, preds_class)
    precision = precision_score(all_targets_indices, preds_class, average='macro', zero_division=0)
    recall = recall_score(all_targets_indices, preds_class, average='macro', zero_division=0)
    
    return avg_loss, auc, accuracy, precision, recall

def get_optimizer(model, cfg):
    if cfg.optimizer == 'Adam':
        return optim.Adam(model.parameters(), lr=cfg.lr, weight_decay=cfg.weight_decay)
    elif cfg.optimizer == 'AdamW':
        return optim.AdamW(model.parameters(), lr=cfg.lr, weight_decay=cfg.weight_decay)
    else:
        raise NotImplementedError
        
def get_criterion(cfg):
    print(f"Using criterion: {cfg.criterion}")
    if cfg.criterion == 'BCEWithLogitsLoss':
        return nn.BCEWithLogitsLoss()
    elif cfg.criterion == 'CE':
        return nn.CrossEntropyLoss()
    elif cfg.criterion == 'MSE':
        return nn.MSELoss()
    else:
        raise NotImplementedError(f"Criterion {cfg.criterion} not implemented")

def get_scheduler(optimizer, cfg, train_loader_len=None):
    if cfg.scheduler == 'CosineAnnealingLR':
        return lr_scheduler.CosineAnnealingLR(optimizer, T_max=cfg.T_max, eta_min=cfg.min_lr)
    elif cfg.scheduler == 'OneCycleLR' and train_loader_len is not None:
         return lr_scheduler.OneCycleLR(
            optimizer, max_lr=cfg.lr, steps_per_epoch=train_loader_len, epochs=cfg.epochs, pct_start=0.1)
    elif cfg.scheduler == 'ReduceLROnPlateau':
        return lr_scheduler.ReduceLROnPlateau(optimizer, mode='max', factor=0.5, patience=2, min_lr=cfg.min_lr, verbose=True)
    else:
        return None

# --- MODIFICATION: 大幅修改 run_training 主函数以集成所有功能 ---
def run_training(df, cfg):
    train_df, val_df = train_test_split(df, test_size=0.2, random_state=cfg.seed)

    print(f'Training set size: {len(train_df)}')
    print(f'Validation set size: {len(val_df)}')

    train_dataset = MusicEmoDataset(train_df)
    val_dataset = MusicEmoDataset(val_df)
    
    train_loader = DataLoader(
        train_dataset, batch_size=cfg.batch_size, shuffle=True, 
        num_workers=cfg.num_workers, pin_memory=True, drop_last=True
    )
    val_loader = DataLoader(
        val_dataset, batch_size=cfg.batch_size, shuffle=False, 
        num_workers=cfg.num_workers, pin_memory=True
    )
    
    device = cfg.device
    model = EfficientNetModel().to(device)
    optimizer = get_optimizer(model, cfg)
    criterion = get_criterion(cfg)
    scheduler = get_scheduler(optimizer, cfg, train_loader_len=len(train_loader))
    
    best_auc = 0
    best_epoch = 0
    
    # 初始化 history 字典以存储所有指标
    history = {
        'train_loss': [], 'val_loss': [],
        'train_auc': [], 'val_auc': [],
        'train_acc': [], 'val_acc': [],
        'train_precision': [], 'val_precision': [],
        'train_recall': [], 'val_recall': []
    }
    
    for epoch in range(cfg.epochs):
        print(f"\nEpoch {epoch+1}/{cfg.epochs}")
        
        # 获取训练集所有指标
        train_loss, train_auc, train_acc, train_precision, train_recall = train_one_epoch(
            model, train_loader, optimizer, criterion, device,
            scheduler if cfg.scheduler == 'OneCycleLR' else None
        )
        
        # 获取验证集所有指标和用于绘图的数据
        val_loss, val_auc, val_acc, val_precision, val_recall, _, _, _ = validate(
            model, val_loader, criterion, device
        )

        if scheduler is not None and cfg.scheduler != 'OneCycleLR':
            if isinstance(scheduler, lr_scheduler.ReduceLROnPlateau):
                scheduler.step(val_auc)
            else:
                scheduler.step()

        # 记录当前 epoch 的所有数据
        history['train_loss'].append(train_loss)
        history['val_loss'].append(val_loss)
        history['train_auc'].append(train_auc)
        history['val_auc'].append(val_auc)
        history['train_acc'].append(train_acc)
        history['val_acc'].append(val_acc)
        history['train_precision'].append(train_precision)
        history['val_precision'].append(val_precision)
        history['train_recall'].append(train_recall)
        history['val_recall'].append(val_recall)
        
        print(f"Train -> Loss: {train_loss:.4f}, AUC: {train_auc:.4f}, Acc: {train_acc:.4f}, Precision: {train_precision:.4f}, Recall: {train_recall:.4f}")
        print(f"Valid -> Loss: {val_loss:.4f}, AUC: {val_auc:.4f}, Acc: {val_acc:.4f}, Precision: {val_precision:.4f}, Recall: {val_recall:.4f}")
        
        if val_auc > best_auc:
            best_auc = val_auc
            best_epoch = epoch + 1
            print(f"🚀 New best AUC: {best_auc:.4f} at epoch {best_epoch}. Saving model...")
            torch.save(model.state_dict(), cfg.model_path_emo)

    print(f"\n🎉 Training finished. Best AUC: {best_auc:.4f} at epoch {best_epoch}.")
    
    # --- 训练结束后，调用所有绘图函数 ---
    print("\nGenerating training history plots...")
    plot_history(history)
    
    print("\nLoading best model to generate final evaluation plots...")
    best_model = EfficientNetModel().to(device)
    best_model.load_state_dict(torch.load(cfg.model_path_emo))
    
    # 重新获取验证集的真实标签、预测类别和预测概率
    _, _, _, _, _, val_targets, val_preds, val_probs = validate(
        best_model, val_loader, criterion, device
    )
    
    class_names = cfg.LABEL_COL

    # 将标签转换为一维索引以用于绘图
    if val_targets.ndim == 2:
        val_targets_indices = np.argmax(val_targets, axis=1)
    else:
        val_targets_indices = val_targets
    
    print("\nGenerating Confusion Matrix...")
    plot_confusion_matrix(val_targets_indices, val_preds, class_names)
    
    print("\nGenerating ROC Curves...")
    plot_roc_curves(val_targets_indices, val_probs, class_names)

    # 清理内存
    del model, best_model, optimizer, scheduler, train_loader, val_loader
    torch.cuda.empty_cache()
    gc.collect()

if __name__ == "__main__":
    print("\nLoading training data...")
    RESULTS_EMOTION.mkdir(parents=True, exist_ok=True)
    train_df = pd.read_csv(cfg.train_csv)
    run_training(train_df, cfg)
    print("\nAll tasks complete!")