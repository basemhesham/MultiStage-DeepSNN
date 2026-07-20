"""
Quantized SNN Evaluation Framework

This script provides tools to compare a PyTorch SNN model with a custom quantized
hardware implementation (using Numba). It includes:
- A PyTorch reference model (DeepSNNClassification_g11)
- Numba-accelerated quantized layers (conv, batch norm, pooling, LIF, dense)
- Functions to capture intermediate activations from both implementations
- Deep comparison routines to validate correctness
- Full evaluation on a test subset with optional quantization sweep

The quantization uses fixed-point arithmetic configurable via total_bits and frac_bits.
"""

from utils.train.train_snn import fourth_step
import torch
import torch.nn as nn
import torch.nn.functional as F
import snntorch as snn
from snntorch import surrogate
from tqdm import tqdm
from sklearn.metrics import accuracy_score, f1_score, classification_report
from numba import njit, prange
import csv
import time
import os
import shutil
import random
import argparse
import numpy as np

# Label mapping for classification
LABEL_MAP = {
    "negative_samples": 0,        # no incident
    "drifting_or_skidding": 1,    # risky but no impact
    "other_crash": 2,             # crash, ego NOT involved
    "collision": 3,                # crash, ego involved (most severe)
}

# ----------------------------------------------------------------------
#  Silence harmless NNPACK warning
# ----------------------------------------------------------------------
torch.backends.nnpack.enabled = False

# ----------------------------------------------------------------------
#  Numba: scalar quantizer (division‑based, manual clamp)
# ----------------------------------------------------------------------


@njit
def quantize_scalar(v, scale, min_val, max_val):
    """Quantize a scalar value using fixed‑point rounding and clamping.

    Args:
        v: Input float value.
        scale: Scaling factor (2^frac_bits).
        min_val: Minimum representable value after scaling.
        max_val: Maximum representable value after scaling.

    Returns:
        Quantized float value (rounded and clamped).
    """
    q = np.round(v * scale)
    int_min = min_val * scale
    int_max = max_val * scale
    if q < int_min:
        q = int_min
    if q > int_max:
        q = int_max
    return q / scale


# ----------------------------------------------------------------------
#  Numba: quantize entire array (elementwise)
# ----------------------------------------------------------------------
@njit(parallel=True)
def quantize_array(arr, scale, min_val, max_val):
    """Quantize every element of an array elementwise.

    Args:
        arr: Input numpy array.
        scale: Scaling factor.
        min_val: Minimum representable value.
        max_val: Maximum representable value.

    Returns:
        Quantized array of same shape.
    """
    out = np.zeros_like(arr)
    int_min = min_val * scale
    int_max = max_val * scale
    for idx in np.ndindex(arr.shape):
        q = np.round(arr[idx] * scale)
        if q < int_min:
            q = int_min
        if q > int_max:
            q = int_max
        out[idx] = q / scale
    return out


# ----------------------------------------------------------------------
#  2. Max Pooling 2x2, stride=2 – channel‑last
# ----------------------------------------------------------------------
@njit(parallel=True)
def myMaxPool2D_numba(x):
    """2x2 max pooling with stride 2 (channel‑last format).

    Args:
        x: Input array of shape (H, W, C).

    Returns:
        Pooled array of shape (H//2, W//2, C).
    """
    H, W, C = x.shape
    Hout = H // 2
    Wout = W // 2
    out = np.zeros((Hout, Wout, C), dtype=x.dtype)
    for c in prange(C):
        for i in range(Hout):
            for j in range(Wout):
                m = x[2*i, 2*j, c]
                v2 = x[2*i+1, 2*j, c]
                v3 = x[2*i, 2*j+1, c]
                v4 = x[2*i+1, 2*j+1, c]
                if v2 > m:
                    m = v2
                if v3 > m:
                    m = v3
                if v4 > m:
                    m = v4
                out[i, j, c] = m
    return out


# ----------------------------------------------------------------------
#  1. Batch Normalization (affine: A*x + B) – channel‑last
# ----------------------------------------------------------------------
@njit(parallel=True)
def myBatchNorm_numba(x, A, B, quant=False, scale=1.0, min_val=0, max_val=255):
    """Apply batch normalization (channel‑last) with optional quantization.

    Args:
        x: Input array (H, W, C).
        A: Scale parameter per channel (C,).
        B: Shift parameter per channel (C,).
        quant: Whether to quantize intermediate results.
        scale, min_val, max_val: Quantization parameters.

    Returns:
        Normalized array (H, W, C).
    """
    H, W, C = x.shape
    out = np.zeros_like(x)
    for c in prange(C):
        for h in range(H):
            for w in range(W):
                v = A[c] * x[h, w, c]
                if quant:
                    v = quantize_scalar(v, scale, min_val, max_val)
                v += B[c]
                if quant:
                    v = quantize_scalar(v, scale, min_val, max_val)
                out[h, w, c] = v
    return out


# ----------------------------------------------------------------------
#  3. Convolution (stride, padding) – weight: (kH, kW, Cin, Cout)
# ----------------------------------------------------------------------
@njit(parallel=True)
def myConv2D_numba(x, weight, bias, stride=1, padding=0,
                   quant=False, scale=1.0, min_val=0, max_val=255):
    """2D convolution with optional quantization (channel‑last format).

    Args:
        x: Input array (H, W, Cin).
        weight: Convolution weights (kH, kW, Cin, Cout).
        bias: Bias per output channel (Cout,).
        stride: Convolution stride.
        padding: Zero padding on each side.
        quant, scale, min_val, max_val: Quantization parameters.

    Returns:
        Output feature map (H_out, W_out, Cout).
    """
    H, W, C_in = x.shape
    kH, kW, _, C_out = weight.shape

    if padding > 0:
        x_pad = np.zeros((H+2*padding, W+2*padding, C_in), dtype=x.dtype)
        x_pad[padding:H+padding, padding:W+padding, :] = x
    else:
        x_pad = x

    Hp, Wp = x_pad.shape[0], x_pad.shape[1]
    H_out = (Hp - kH) // stride + 1
    W_out = (Wp - kW) // stride + 1
    out = np.zeros((H_out, W_out, C_out), dtype=x.dtype)

    for co in prange(C_out):
        for ci in range(C_in):
            for kh in range(kH):
                for kw in range(kW):
                    w_val = weight[kh, kw, ci, co]
                    for h in range(H_out):
                        h_in = h * stride + kh
                        for w in range(W_out):
                            w_in = w * stride + kw
                            prod = x_pad[h_in, w_in, ci] * w_val
                            if quant:
                                prod = quantize_scalar(
                                    prod, scale, min_val, max_val)
                            out[h, w, co] += prod
                            if quant:
                                out[h, w, co] = quantize_scalar(
                                    out[h, w, co], scale, min_val, max_val)

    for co in prange(C_out):
        bias_val = bias[co]
        for h in range(H_out):
            for w in range(W_out):
                val = out[h, w, co] + bias_val
                if quant:
                    val = quantize_scalar(val, scale, min_val, max_val)
                out[h, w, co] = val
    return out


# ----------------------------------------------------------------------
#  4. LIF Neuron (one timestep, hard reset, reset_delay=True)
# ----------------------------------------------------------------------
@njit(parallel=True)
def myLIF_numba_quant(spk_in, x, mem, beta, threshold,
                      quant, scale, min_val, max_val):
    """Leaky Integrate-and-Fire neuron for one timestep (channel‑last).

    Args:
        spk_in: Input spikes from previous timestep (H, W, C).
        x: Synaptic current (H, W, C).
        mem: Membrane potential from previous timestep (H, W, C).
        beta: Leak decay factor.
        threshold: Firing threshold.
        quant, scale, min_val, max_val: Quantization parameters.

    Returns:
        spk_out: Output spikes (H, W, C).
        new_mem: Updated membrane potential (H, W, C).
    """
    H, W, C = x.shape
    spk_out = np.zeros_like(mem)
    new_mem = np.zeros_like(mem)

    beta = np.float32(beta)
    threshold = np.float32(threshold)
    scale = np.float32(scale)
    min_val = np.float32(min_val)
    max_val = np.float32(max_val)

    for i in prange(H):
        for j in range(W):
            for k in range(C):
                prod = beta * mem[i, j, k]
                if quant:
                    prod = quantize_scalar(prod, scale, min_val, max_val)

                sum1 = prod + x[i, j, k]
                if quant:
                    sum1 = quantize_scalar(sum1, scale, min_val, max_val)

                reset_term = spk_in[i, j, k] * threshold
                if quant:
                    reset_term = quantize_scalar(
                        reset_term, scale, min_val, max_val)

                m = sum1 - reset_term
                if quant:
                    m = quantize_scalar(m, scale, min_val, max_val)

                s = 1.0 if m >= threshold else 0.0
                if quant:
                    s = quantize_scalar(s, scale, min_val, max_val)

                spk_out[i, j, k] = s
                new_mem[i, j, k] = m
    return spk_out, new_mem


# ----------------------------------------------------------------------
#  5. Global Average Pooling – channel‑last
# ----------------------------------------------------------------------
@njit(parallel=True)
def myGAP_numba(x, quant=False, scale=1.0, min_val=0, max_val=255):
    """Global average pooling over spatial dimensions (channel‑last).

    Args:
        x: Input array (H, W, C).
        quant, scale, min_val, max_val: Quantization parameters.

    Returns:
        Pooled vector (C,).
    """
    H, W, C = x.shape
    out = np.zeros(C, dtype=np.float32)
    for c in prange(C):
        acc = 0.0
        for h in range(H):
            for w in range(W):
                acc += x[h, w, c]
        acc /= (H * W)
        if quant:
            acc = quantize_scalar(acc, scale, min_val, max_val)
        out[c] = acc
    return out


# ----------------------------------------------------------------------
#  6. Dense (Fully Connected) – optional ReLU, per‑product quant
# ----------------------------------------------------------------------
@njit(parallel=True)
def myDense_numba(x, W, b, relu=False,
                  quant=False, scale=1.0, min_val=0, max_val=255):
    """Fully connected layer with optional ReLU and quantization.

    Args:
        x: Input vector (Nin,).
        W: Weight matrix (Nin, Nout).
        b: Bias vector (Nout,).
        relu: Whether to apply ReLU activation.
        quant, scale, min_val, max_val: Quantization parameters.

    Returns:
        Output vector (Nout,).
    """
    Nin, Nout = W.shape
    out = np.zeros(Nout, dtype=np.float32)
    for o in prange(Nout):
        acc = 0.0
        for i in range(Nin):
            val = x[i] * W[i, o]
            if quant:
                val = quantize_scalar(val, scale, min_val, max_val)
            acc += val
            if quant:
                acc = quantize_scalar(acc, scale, min_val, max_val)
        acc += b[o]
        if relu and acc < 0:
            acc = 0.0
        if quant:
            acc = quantize_scalar(acc, scale, min_val, max_val)
        out[o] = acc
    return out


# ======================================================================
#  PyTorch Model (Reference) – exactly as in your training
# ======================================================================
class DeepSNNClassification_g11(nn.Module):
    """Reference SNN model with three convolutional blocks and two fully connected layers.

    Architecture:
        - Conv1 (5x5, 1->32) + BN + MaxPool2d + LIF
        - Conv2 (3x3, 32->64) + BN + MaxPool2d + LIF
        - Conv3 (3x3, 64->128) + BN + MaxPool2d + LIF
        - Global Average Pooling
        - FC1 (128->256) + ReLU + Dropout
        - FC2 (256->num_classes)

    Args:
        num_classes: Number of output classes.
        beta: LIF neuron decay factor.
        spike_grad: Surrogate gradient function for LIF.
        dropout_prob: Dropout probability.
    """

    def __init__(self, num_classes, beta=0.9, spike_grad=surrogate.atan(), dropout_prob=0.4):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 32, 5, padding=2)
        self.bn1 = nn.BatchNorm2d(32)
        self.pool1 = nn.MaxPool2d(2)
        self.lif1 = snn.Leaky(beta=beta, spike_grad=spike_grad)

        self.conv2 = nn.Conv2d(32, 64, 3, padding=1)
        self.bn2 = nn.BatchNorm2d(64)
        self.pool2 = nn.MaxPool2d(2)
        self.lif2 = snn.Leaky(beta=beta, spike_grad=spike_grad)

        self.conv3 = nn.Conv2d(64, 128, 3, padding=1)
        self.bn3 = nn.BatchNorm2d(128)
        self.pool3 = nn.MaxPool2d(2)
        self.lif3 = snn.Leaky(beta=beta, spike_grad=spike_grad)

        self.global_pool = nn.AdaptiveAvgPool2d((1, 1))
        self.fc1 = nn.Linear(128, 256)
        self.dropout = nn.Dropout(dropout_prob)
        self.fc2 = nn.Linear(256, num_classes)

    def forward(self, x):
        """Forward pass through time.

        Args:
            x: Input tensor of shape (B, T, H, W, C) – assumed channel‑last.

        Returns:
            Logits of shape (B, num_classes).
        """
        # Convert to channel‑first for PyTorch layers
        x = x.permute(0, 1, 4, 2, 3)

        self.lif1.reset_mem()
        self.lif2.reset_mem()
        self.lif3.reset_mem()

        B, T, _, _, _ = x.shape
        mem1 = mem2 = mem3 = None

        for t in range(T):
            xt = x[:, t]
            out = self.pool1(self.bn1(self.conv1(xt)))
            spk1, mem1 = self.lif1(out, mem1)

            out = self.pool2(self.bn2(self.conv2(spk1)))
            spk2, mem2 = self.lif2(out, mem2)

            out = self.pool3(self.bn3(self.conv3(spk2)))
            spk3, mem3 = self.lif3(out, mem3)

        out = self.global_pool(spk3)
        out = out.reshape(B, -1)
        out = F.relu(self.fc1(out))
        out = self.dropout(out)
        return self.fc2(out)


# ======================================================================
#  PyTorch intermediate capture (channel‑first)
# ======================================================================
def get_pt_intermediates(model, x_batch):
    """Capture intermediate activations from the PyTorch model for a single sample.

    Args:
        model: Trained DeepSNNClassification_g11 model.
        x_batch: Input batch of shape (1, T, H, W, C).

    Returns:
        Dictionary mapping layer names to numpy arrays of activations.
    """
    model.eval()
    x = x_batch.float().to(next(model.parameters()).device)
    B, T, H, W, C = x.shape
    x = x.permute(0, 1, 4, 2, 3)

    model.lif1.reset_mem()
    model.lif2.reset_mem()
    model.lif3.reset_mem()
    mem1 = mem2 = mem3 = None
    intermediates = {}

    for t in range(T):
        xt = x[:, t]

        out = model.conv1(xt)
        intermediates['conv1'] = out[0].detach().cpu().numpy()
        out = model.bn1(out)
        intermediates['bn1'] = out[0].detach().cpu().numpy()
        out = model.pool1(out)
        intermediates['pool1'] = out[0].detach().cpu().numpy()
        spk1, mem1 = model.lif1(out, mem1)
        intermediates['lif1_spk'] = spk1[0].detach().cpu().numpy()
        intermediates['lif1_mem'] = mem1[0].detach().cpu().numpy()

        out = model.conv2(spk1)
        intermediates['conv2'] = out[0].detach().cpu().numpy()
        out = model.bn2(out)
        intermediates['bn2'] = out[0].detach().cpu().numpy()
        out = model.pool2(out)
        intermediates['pool2'] = out[0].detach().cpu().numpy()
        spk2, mem2 = model.lif2(out, mem2)
        intermediates['lif2_spk'] = spk2[0].detach().cpu().numpy()
        intermediates['lif2_mem'] = mem2[0].detach().cpu().numpy()

        out = model.conv3(spk2)
        intermediates['conv3'] = out[0].detach().cpu().numpy()
        out = model.bn3(out)
        intermediates['bn3'] = out[0].detach().cpu().numpy()
        out = model.pool3(out)
        intermediates['pool3'] = out[0].detach().cpu().numpy()
        spk3, mem3 = model.lif3(out, mem3)
        intermediates['lif3_spk'] = spk3[0].detach().cpu().numpy()
        intermediates['lif3_mem'] = mem3[0].detach().cpu().numpy()

    out = model.global_pool(spk3).reshape(B, -1)
    intermediates['gap'] = out[0].detach().cpu().numpy()
    out = model.fc1(out)
    intermediates['fc1'] = out[0].detach().cpu().numpy()
    out = F.relu(out)
    intermediates['fc1_relu'] = out[0].detach().cpu().numpy()
    out = model.dropout(out)   # eval → identity
    out = model.fc2(out)
    intermediates['fc2'] = out[0].detach().cpu().numpy()
    return intermediates


# ======================================================================
#  Hardware Model Wrapper (Numba) – WITH CORRECT LIF PARAMETERS
# ======================================================================
class CustomQuantizedG11:
    """Hardware‑style model using Numba‑accelerated quantized layers.

    This class replicates the PyTorch model's computation using custom Numba
    functions. It supports both floating‑point emulation (quantization=False)
    and fixed‑point quantization (quantization=True) configurable via total_bits
    and frac_bits.

    Attributes:
        quant: Whether quantization is enabled.
        scale: Scaling factor (2^frac_bits).
        min_val: Minimum representable value.
        max_val: Maximum representable value.
        beta1, beta2, beta3: LIF decay factors.
        thresh1, thresh2, thresh3: LIF thresholds.
        w1, b1, w2, b2, w3, b3: Quantized convolution weights and biases.
        bn1_A, bn1_B, ...: Fused batch norm parameters.
        w_fc1, b_fc1, w_fc2, b_fc2: Quantized FC weights and biases.
    """

    def __init__(self, pt_model, quantization=True, total_bits=16, frac_bits=10):
        """Initialize hardware model from a trained PyTorch model.

        Args:
            pt_model: Trained DeepSNNClassification_g11 model.
            quantization: Whether to enable fixed‑point quantization.
            total_bits: Total number of bits for fixed‑point representation.
            frac_bits: Number of fractional bits.
        """
        self.quant = quantization
        self.scale = 2**frac_bits
        self.min_val = -(2**(total_bits-1)) / self.scale
        self.max_val = (2**(total_bits-1)-1) / self.scale

        # Extract LIF parameters
        self.beta1 = pt_model.lif1.beta.detach().cpu().numpy().item()
        self.beta2 = pt_model.lif2.beta.detach().cpu().numpy().item()
        self.beta3 = pt_model.lif3.beta.detach().cpu().numpy().item()
        self.thresh1 = pt_model.lif1.threshold.detach().cpu().numpy().item()
        self.thresh2 = pt_model.lif2.threshold.detach().cpu().numpy().item()
        self.thresh3 = pt_model.lif3.threshold.detach().cpu().numpy().item()

        # Convolution parameters
        self.pad1 = pt_model.conv1.padding[0]
        self.pad2 = pt_model.conv2.padding[0]
        self.pad3 = pt_model.conv3.padding[0]
        self.stride1 = pt_model.conv1.stride[0]
        self.stride2 = pt_model.conv2.stride[0]
        self.stride3 = pt_model.conv3.stride[0]

        def get_wb(conv):
            w = conv.weight.data.cpu().numpy().transpose(2, 3, 1, 0)  # (Kh, Kw, Cin, Cout)
            b = conv.bias.data.cpu().numpy()
            return w, b

        w1, b1 = get_wb(pt_model.conv1)
        w2, b2 = get_wb(pt_model.conv2)
        w3, b3 = get_wb(pt_model.conv3)

        def fuse_bn(bn):
            g = bn.weight.data.cpu().numpy()
            b = bn.bias.data.cpu().numpy()
            m = bn.running_mean.data.cpu().numpy()
            v = bn.running_var.data.cpu().numpy()
            eps = 1e-5
            A = g / np.sqrt(v + eps)
            B = b - g * m / np.sqrt(v + eps)
            return A, B

        self.bn1_A, self.bn1_B = fuse_bn(pt_model.bn1)
        self.bn2_A, self.bn2_B = fuse_bn(pt_model.bn2)
        self.bn3_A, self.bn3_B = fuse_bn(pt_model.bn3)

        self.w_fc1 = pt_model.fc1.weight.data.cpu().numpy().T
        self.b_fc1 = pt_model.fc1.bias.data.cpu().numpy()
        self.w_fc2 = pt_model.fc2.weight.data.cpu().numpy().T
        self.b_fc2 = pt_model.fc2.bias.data.cpu().numpy()

        if self.quant:
            self.w1 = quantize_array(
                w1, self.scale, self.min_val, self.max_val)
            self.b1 = quantize_array(
                b1, self.scale, self.min_val, self.max_val)
            self.w2 = quantize_array(
                w2, self.scale, self.min_val, self.max_val)
            self.b2 = quantize_array(
                b2, self.scale, self.min_val, self.max_val)
            self.w3 = quantize_array(
                w3, self.scale, self.min_val, self.max_val)
            self.b3 = quantize_array(
                b3, self.scale, self.min_val, self.max_val)
            self.bn1_A = quantize_array(
                self.bn1_A, self.scale, self.min_val, self.max_val)
            self.bn1_B = quantize_array(
                self.bn1_B, self.scale, self.min_val, self.max_val)
            self.bn2_A = quantize_array(
                self.bn2_A, self.scale, self.min_val, self.max_val)
            self.bn2_B = quantize_array(
                self.bn2_B, self.scale, self.min_val, self.max_val)
            self.bn3_A = quantize_array(
                self.bn3_A, self.scale, self.min_val, self.max_val)
            self.bn3_B = quantize_array(
                self.bn3_B, self.scale, self.min_val, self.max_val)
            self.w_fc1 = quantize_array(
                self.w_fc1, self.scale, self.min_val, self.max_val)
            self.b_fc1 = quantize_array(
                self.b_fc1, self.scale, self.min_val, self.max_val)
            self.w_fc2 = quantize_array(
                self.w_fc2, self.scale, self.min_val, self.max_val)
            self.b_fc2 = quantize_array(
                self.b_fc2, self.scale, self.min_val, self.max_val)
        else:
            self.w1, self.b1 = w1, b1
            self.w2, self.b2 = w2, b2
            self.w3, self.b3 = w3, b3

    def forward(self, x, return_intermediates=False):
        """Forward pass through the hardware model.

        Args:
            x: Input numpy array of shape (1, T, H, W) or (1, T, H, W, 1).
            return_intermediates: If True, return a dict of layer outputs.

        Returns:
            If return_intermediates: (logits, intermediates_dict)
            Else: logits as numpy array of shape (num_classes,).
        """
        x = x[0]                # (T, H, W) or (T, H, W, C)
        if x.ndim == 3:
            x = np.expand_dims(x, axis=-1)  # (T, H, W, 1)
        T, H, W, C = x.shape

        # Initialise membrane potentials (channel‑last)
        mem1 = np.zeros((H//2, W//2, 32), dtype=np.float32)
        mem2 = np.zeros((H//4, W//4, 64), dtype=np.float32)
        mem3 = np.zeros((H//8, W//8, 128), dtype=np.float32)
        spk1 = np.zeros((H//2, W//2, 32), dtype=np.float32)
        spk2 = np.zeros((H//4, W//4, 64), dtype=np.float32)
        spk3 = np.zeros((H//8, W//8, 128), dtype=np.float32)
        intermediates = {} if return_intermediates else None

        for t in range(T):
            xt = x[t]
            if self.quant:
                xt = quantize_array(xt, self.scale, self.min_val, self.max_val)

            # ---- Block 1 ----
            out = myConv2D_numba(xt, self.w1, self.b1,
                                 stride=self.stride1, padding=self.pad1,
                                 quant=self.quant, scale=self.scale,
                                 min_val=self.min_val, max_val=self.max_val)
            if return_intermediates:
                intermediates['conv1'] = out.copy()
            out = myBatchNorm_numba(out, self.bn1_A, self.bn1_B,
                                    self.quant, self.scale, self.min_val, self.max_val)
            if return_intermediates:
                intermediates['bn1'] = out.copy()
            out = myMaxPool2D_numba(out)
            if return_intermediates:
                intermediates['pool1'] = out.copy()
            spk1, mem1 = myLIF_numba_quant(spk1, out, mem1,
                                           beta=self.beta1, threshold=self.thresh1,
                                           quant=self.quant, scale=self.scale,
                                           min_val=self.min_val, max_val=self.max_val)
            if return_intermediates:
                intermediates['lif1_spk'] = spk1.copy()
                intermediates['lif1_mem'] = mem1.copy()

            # ---- Block 2 ----
            out = myConv2D_numba(spk1, self.w2, self.b2,
                                 stride=self.stride2, padding=self.pad2,
                                 quant=self.quant, scale=self.scale,
                                 min_val=self.min_val, max_val=self.max_val)
            if return_intermediates:
                intermediates['conv2'] = out.copy()
            out = myBatchNorm_numba(out, self.bn2_A, self.bn2_B,
                                    self.quant, self.scale, self.min_val, self.max_val)
            if return_intermediates:
                intermediates['bn2'] = out.copy()
            out = myMaxPool2D_numba(out)
            if return_intermediates:
                intermediates['pool2'] = out.copy()
            spk2, mem2 = myLIF_numba_quant(spk2, out, mem2,
                                           beta=self.beta2, threshold=self.thresh2,
                                           quant=self.quant, scale=self.scale,
                                           min_val=self.min_val, max_val=self.max_val)
            if return_intermediates:
                intermediates['lif2_spk'] = spk2.copy()
                intermediates['lif2_mem'] = mem2.copy()

            # ---- Block 3 ----
            out = myConv2D_numba(spk2, self.w3, self.b3,
                                 stride=self.stride3, padding=self.pad3,
                                 quant=self.quant, scale=self.scale,
                                 min_val=self.min_val, max_val=self.max_val)
            if return_intermediates:
                intermediates['conv3'] = out.copy()
            out = myBatchNorm_numba(out, self.bn3_A, self.bn3_B,
                                    self.quant, self.scale, self.min_val, self.max_val)
            if return_intermediates:
                intermediates['bn3'] = out.copy()
            out = myMaxPool2D_numba(out)
            if return_intermediates:
                intermediates['pool3'] = out.copy()
            spk3, mem3 = myLIF_numba_quant(spk3, out, mem3,
                                           beta=self.beta3, threshold=self.thresh3,
                                           quant=self.quant, scale=self.scale,
                                           min_val=self.min_val, max_val=self.max_val)
            if return_intermediates:
                intermediates['lif3_spk'] = spk3.copy()
                intermediates['lif3_mem'] = mem3.copy()

        # ---- Global Average Pooling ----
        out = myGAP_numba(spk3, self.quant, self.scale,
                          self.min_val, self.max_val)
        if return_intermediates:
            intermediates['gap'] = out.copy()

        # ---- FC1 + ReLU ----
        out = myDense_numba(out, self.w_fc1, self.b_fc1, relu=True,
                            quant=self.quant, scale=self.scale,
                            min_val=self.min_val, max_val=self.max_val)
        if return_intermediates:
            intermediates['fc1'] = out.copy()

        # ---- FC2 (no ReLU) ----
        out = myDense_numba(out, self.w_fc2, self.b_fc2, relu=False,
                            quant=self.quant, scale=self.scale,
                            min_val=self.min_val, max_val=self.max_val)
        if return_intermediates:
            intermediates['fc2'] = out.copy()

        if return_intermediates:
            return out, intermediates
        return out


# ======================================================================
#  Enhanced Deep Comparison (single sample) with spike mismatch counting
# ======================================================================
def deep_compare(pt_model, hw_model, sample_batch,
                 rtol=1e-3, atol=1e-3,
                 spike_mismatch_threshold=0.02):
    """Perform a detailed layer‑by‑layer comparison on a single sample.

    Args:
        pt_model: PyTorch model.
        hw_model: CustomQuantizedG11 model.
        sample_batch: A batch dict with 'video' tensor.
        rtol, atol: Relative and absolute tolerance for non‑spike tensors.
        spike_mismatch_threshold: Allowed spike mismatch rate.

    Returns:
        True if all layers match within tolerance and predictions agree.
    """
    print("\n🔬 DEEP COMPARISON (quantization OFF) – single sample")
    print("=" * 70)
    x_np = sample_batch['video'].float().cpu().numpy()
    pt_ints = get_pt_intermediates(pt_model, sample_batch['video'])
    hw_out, hw_ints = hw_model.forward(x_np, return_intermediates=True)

    all_match = True
    spike_mismatch_rates = {}

    for key in hw_ints.keys():
        if key not in pt_ints:
            continue

        pt_val = pt_ints[key]
        hw_val = hw_ints[key]

        # Convert HW layout (H,W,C) -> (C,H,W) for comparison
        if hw_val.ndim == 3:
            hw_val_perm = hw_val.transpose(2, 0, 1)
        else:
            hw_val_perm = hw_val

        if '_spk' in key:
            mismatches = np.sum(pt_val != hw_val_perm)
            total_pixels = pt_val.size
            mismatch_rate = mismatches / total_pixels
            spike_mismatch_rates[key] = (
                mismatches, total_pixels, mismatch_rate)

            if mismatches == 0:
                print(f"✅ {key:15s} : perfect match (0 mismatches)")
            else:
                print(f"❌ {key:15s} : {mismatches:5d} / {total_pixels:6d} spikes differ "
                      f"({mismatch_rate:.4%})")
                if mismatch_rate <= spike_mismatch_threshold:
                    print(
                        f"   (✓ below threshold {spike_mismatch_threshold:.2%})")
                else:
                    all_match = False
        else:
            try:
                np.testing.assert_allclose(
                    pt_val, hw_val_perm, rtol=rtol, atol=atol)
                print(f"✅ {key:15s} : match")
            except AssertionError:
                max_diff = np.max(np.abs(pt_val - hw_val_perm))
                mean_diff = np.mean(np.abs(pt_val - hw_val_perm))
                print(
                    f"❌ {key:15s} : mismatch (max diff={max_diff:.6f}, mean diff={mean_diff:.6f})")
                all_match = False

    pt_pred = np.argmax(pt_ints['fc2'])
    hw_pred = np.argmax(hw_out)
    print(f"\nPyTorch prediction : {pt_pred}")
    print(f"HW prediction      : {hw_pred}")
    if pt_pred == hw_pred:
        print("✅ Final predictions match!")
    else:
        print("❌ Final predictions differ!")
        all_match = False

    if all_match:
        print("\n🎉 All layers match within tolerance! HW model is correct (before quantization).")
    else:
        print("\n⚠️  Some mismatches – evaluating significance...")
        spike_ok = all(rate <= spike_mismatch_threshold
                       for _, _, rate in spike_mismatch_rates.values())
        if spike_ok and pt_pred == hw_pred:
            print(f"   ✅ But spike mismatch rate ≤ {spike_mismatch_threshold:.2%} "
                  "and predictions match → model is FUNCTIONALLY CORRECT.")
            all_match = True
        else:
            print(
                "   ❌ Model not accepted – either predictions differ or spike mismatch exceeds threshold.")
    return all_match


# ======================================================================
#  DEEP COMPARISON ON SUBSET (many samples) – per‑layer statistics + final metrics
# ======================================================================
def deep_compare_subset(pt_model, hw_model, loader, num_samples=50,
                        rtol=1e-3, atol=1e-3,
                        spike_mismatch_threshold=0.001, strings_=True):
    """Run per‑layer comparison on a random subset of samples.

    Args:
        pt_model: PyTorch model.
        hw_model: CustomQuantizedG11 model.
        loader: DataLoader yielding batches.
        num_samples: Number of samples to evaluate.
        rtol, atol: Tolerance for non‑spike tensors.
        spike_mismatch_threshold: Allowed spike mismatch rate per layer.
        strings_: If True, labels are strings; else numeric.

    Returns:
        passed: Boolean indicating whether all criteria were met.
        stats: Dictionary of per‑layer statistics.
        pt_metrics: Dict with accuracy and F1 for PyTorch.
        hw_metrics: Dict with accuracy and F1 for hardware model.
    """
    all_batches = []
    for i, batch in enumerate(loader):
        if i >= 1000:
            break
        all_batches.append(batch)
    n_samples = min(num_samples, len(all_batches))
    sampled_batches = random.sample(all_batches, n_samples)

    print(f"\n🔬 DEEP COMPARISON ON {n_samples} RANDOM SAMPLES")
    print("=" * 80)

    stats = {}
    pt_preds = []
    hw_preds = []
    true_labels = []

    for idx, batch in enumerate(tqdm(sampled_batches, desc="Processing samples")):
        x_np = batch["video"].float().cpu().numpy()
        pt_ints = get_pt_intermediates(pt_model, batch["video"])
        pt_out = pt_model(batch["video"].float().to(
            next(pt_model.parameters()).device))
        pt_pred = pt_out.argmax(1).item()

        hw_out, hw_ints = hw_model.forward(x_np, return_intermediates=True)
        hw_pred = np.argmax(hw_out)

        if strings_:
            true_label = LABEL_MAP[batch["label"][0]]
        else:
            true_label = batch["label"][0].item()

        if isinstance(true_label, torch.Tensor):
            true_label = true_label.item()
        elif isinstance(true_label, (list, np.ndarray)) and len(true_label) == 1:
            true_label = true_label[0]
        true_labels.append(true_label)
        pt_preds.append(pt_pred)
        hw_preds.append(hw_pred)

        for key in hw_ints.keys():
            if key not in pt_ints:
                continue

            pt_val = pt_ints[key]
            hw_val = hw_ints[key]

            if hw_val.ndim == 3:
                hw_val_perm = hw_val.transpose(2, 0, 1)
            else:
                hw_val_perm = hw_val

            if key not in stats:
                stats[key] = {
                    'type': 'spike' if '_spk' in key else 'tensor',
                    'diffs': [],
                    'mismatches': [],
                    'total_pixels': pt_val.size if '_spk' in key else None
                }

            if '_spk' in key:
                mismatches = np.sum(pt_val != hw_val_perm)
                stats[key]['mismatches'].append(mismatches)
            else:
                diff = np.abs(pt_val - hw_val_perm)
                stats[key]['diffs'].append({
                    'max': np.max(diff),
                    'mean': np.mean(diff)
                })

        if (idx + 1) % 10 == 0:
            print(f"  Processed {idx + 1}/{n_samples} samples...")

    # Print per‑layer statistics
    print("\n" + "=" * 80)
    print(f"{'Layer':<20} {'Type':<10} {'Metric':<30} {'Value':<15}")
    print("=" * 80)

    all_layers_pass = True
    for layer, data in sorted(stats.items()):
        if data['type'] == 'spike':
            mismatches = np.array(data['mismatches'])
            total_pixels = data['total_pixels']
            avg_mismatches = mismatches.mean()
            max_mismatches = mismatches.max()
            avg_rate = avg_mismatches / total_pixels
            max_rate = max_mismatches / total_pixels

            pass_layer = avg_rate <= spike_mismatch_threshold
            if not pass_layer:
                all_layers_pass = False

            status = "✅ PASS" if pass_layer else "❌ FAIL"
            print(
                f"{layer:<20} {'spike':<10} {'Avg mismatches':<30} {avg_mismatches:.3f} / {total_pixels} ({avg_rate:.4%})")
            print(
                f"{'':<20} {'':<10} {'Max mismatches':<30} {max_mismatches} ({max_rate:.4%})")
            print(
                f"{'':<20} {'':<10} {'Threshold':<30} ≤ {spike_mismatch_threshold:.2%} {status}")
        else:
            diffs_max = [d['max'] for d in data['diffs']]
            diffs_mean = [d['mean'] for d in data['diffs']]

            avg_max = np.mean(diffs_max)
            max_max = np.max(diffs_max)
            avg_mean = np.mean(diffs_mean)
            max_mean = np.max(diffs_mean)

            print(f"{layer:<20} {'tensor':<10} {'Avg max diff':<30} {avg_max:.6f}")
            print(f"{'':<20} {'':<10} {'Max max diff':<30} {max_max:.6f}")
            print(f"{'':<20} {'':<10} {'Avg mean diff':<30} {avg_mean:.6f}")
            print(f"{'':<20} {'':<10} {'Max mean diff':<30} {max_mean:.6f}")

    # Prediction agreement
    print("\n" + "=" * 80)
    print("FINAL PREDICTION AGREEMENT")
    pred_matches = sum(1 for pt, hw in zip(pt_preds, hw_preds) if pt == hw)
    pred_rate = pred_matches / n_samples
    print(
        f"  Prediction match rate: {pred_matches}/{n_samples} ({pred_rate:.2%})")
    pred_ok = pred_rate == 1.0

    # Overall metrics
    print("\n" + "=" * 80)
    print("CLASSIFICATION PERFORMANCE ON SUBSET")
    print("=" * 80)

    pt_acc = accuracy_score(true_labels, pt_preds)
    pt_f1 = f1_score(true_labels, pt_preds, average="macro", zero_division=0)
    print("\n📈 PyTorch Model (float):")
    print(f"  Accuracy: {pt_acc:.4f}")
    print(f"  Macro F1 : {pt_f1:.4f}")
    print("\n  Classification Report:")
    print(classification_report(true_labels, pt_preds, zero_division=0))

    hw_acc = accuracy_score(true_labels, hw_preds)
    hw_f1 = f1_score(true_labels, hw_preds, average="macro", zero_division=0)
    print("\n📈 Hardware Model (quantization OFF):")
    print(f"  Accuracy: {hw_acc:.4f}")
    print(f"  Macro F1 : {hw_f1:.4f}")
    print("\n  Classification Report:")
    print(classification_report(true_labels, hw_preds, zero_division=0))

    # Final verdict
    print("\n" + "=" * 80)
    if all_layers_pass and pred_ok:
        print(
            "🎉 DEEP COMPARISON PASSED: All layers meet tolerance, predictions match 100%.")
        passed = True
    else:
        print("❌ DEEP COMPARISON FAILED:")
        if not all_layers_pass:
            print("   - Some spike layers exceed mismatch threshold.")
        if not pred_ok:
            print(
                f"   - Prediction match rate = {pred_rate:.2%} (must be 100%).")
        passed = False
    print("=" * 80)

    pt_metrics = {'accuracy': pt_acc, 'f1': pt_f1}
    hw_metrics = {'accuracy': hw_acc, 'f1': hw_f1}
    return passed, stats, pt_metrics, hw_metrics


# ======================================================================
#  Evaluation functions (full test set) – robust label handling
# ======================================================================
@torch.no_grad()
def eval_float_model(model, loader, device, class_names=None, end_batch=None):
    """Evaluate PyTorch model on a data loader.

    Args:
        model: PyTorch model.
        loader: DataLoader.
        device: torch device.
        class_names: Optional list of class names for printing report.
        end_batch: Stop after this many batches (optional).

    Returns:
        acc: Accuracy.
        f1: Macro F1 score.
    """
    y_true, y_pred = [], []
    batch_number = 0
    for batch in loader:
        x = batch["video"].to(device).float()
        if end_batch is not None:
            y = batch["label"][0].item()
        else:
            y = LABEL_MAP[batch["label"][0]]

        out = model(x)
        p = out.argmax(1).item()
        y_true.append(y)
        y_pred.append(p)
        batch_number += 1
        if batch_number == end_batch:
            break

    acc = accuracy_score(y_true, y_pred)
    f1 = f1_score(y_true, y_pred, average="macro", zero_division=0)
    print("\nFLOAT MODEL EVAL COMPLETE")
    print(f"Acc = {acc:.4f}, F1 = {f1:.4f}")
    if class_names is not None:
        labels = sorted(set(y_true))
        target_names = [class_names[i] for i in labels]
        print("\nClassification Report:")
        print(classification_report(y_true, y_pred, labels=labels,
                                    target_names=target_names, zero_division=0))
    return acc, f1


def verify_stage1_hardware():
    """Standalone verification routine injected directly into kd_quant.py"""
    import sys
    print("\n--- Running Stage 1 Hardware Verification (256x256) ---")

    # 1. Initialize EXACT model from this file
    model = DeepSNNClassification_g11(num_classes=4)
    model.eval()

    def to_signed(val_hex, bits=18):
        val = int(val_hex.strip(), 16)
        if val >= (1 << (bits - 1)):
            val -= (1 << bits)
        return val

    # 2. Load Weights (Using exact float64 to prevent large sum errors)
    print("Loading filter_800.hex...")
    try:
        with open("filter_800.hex", "r") as f:
            weights = [to_signed(line) for line in f if line.strip()]
    except FileNotFoundError:
        print("❌ Error: 'filter_800.hex' not found.")
        sys.exit(1)

    weights_tensor = torch.tensor(
        weights, dtype=torch.float64).reshape(32, 1, 5, 5)
    model.conv1.weight.data = weights_tensor
    model.conv1.bias.data.zero_()

    # 3. Load Dummy Image
    print("Loading dummy_image_256x256.hex...")
    try:
        with open("dummy_image_256x256.hex", "r") as f:
            pixels = [to_signed(line) for line in f if line.strip()]
    except FileNotFoundError:
        print("❌ Error: 'dummy_image_256x256.hex' not found.")
        sys.exit(1)

    image_tensor = torch.tensor(
        pixels, dtype=torch.float64).reshape(1, 1, 256, 256)

    # 4. Run PyTorch Conv2D
    print("Running PyTorch Conv2D (Handles padding=2 automatically)...")
    with torch.no_grad():
        out_tensor = model.conv1(image_tensor)

    out_np = out_tensor.numpy()[0]  # Shape: (32, 256, 256)

    # 5. Write exactly formatted output
    output_file = "pt_conv_stg_1.txt"
    with open(output_file, "w") as f:
        for c in range(32):
            f.write(f"--- Channel {c:02d} ---\n")
            for h in range(256):
                row_str = " ".join([str(int(val)) for val in out_np[c, h, :]])
                f.write(row_str + "\n")

    print(f"✅ Success! PyTorch output written to '{output_file}'\n")


def eval_hw_model(hw_model, loader, class_names=None, duration_file="logs/hw_batch_durations.txt", verbose=True, end_batch=None):
    """Evaluate hardware model on a data loader, recording batch durations.

    Args:
        hw_model: CustomQuantizedG11 model.
        loader: DataLoader.
        class_names: Optional list of class names.
        duration_file: Path to CSV file for logging batch times.
        verbose: Print progress every 50 batches.
        end_batch: Stop after this many batches.

    Returns:
        acc: Accuracy.
        f1: Macro F1 score.
    """
    y_true, y_pred = [], []
    batch_number = 0
    seconds_total = 0
    total_batches = len(loader)

    os.makedirs(os.path.dirname(duration_file), exist_ok=True)
    if os.path.exists(duration_file):
        shutil.move(duration_file,
                    f"{duration_file.rstrip('.txt')}_backup.txt")

    with open(duration_file, "a", buffering=1) as f:
        if os.path.getsize(duration_file) == 0:
            f.write("Batch_Number,Duration_Seconds,End_Time\n")

        for batch in loader:
            start = time.time()
            x = batch["video"].float().cpu().numpy()
            if end_batch is not None:
                y = batch["label"][0].item()
            else:
                y = LABEL_MAP[batch["label"][0]]
            out = hw_model.forward(x)
            p = np.argmax(out)
            y_true.append(y)
            y_pred.append(p)
            dur = time.time() - start
            seconds_total += dur
            if end_batch is not None:
                print(
                    f"Batch {batch_number}/{end_batch} – Duration: {dur:.4f}s, Cumulative: {seconds_total:.2f}s")
            f.write(
                f"{batch_number},{dur:.4f},{time.strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.flush()

            batch_number += 1

            if verbose and batch_number % 50 == 0:
                print(
                    f"    ... processed {batch_number}/{total_batches} batches")

            if batch_number == end_batch:
                break

    acc = accuracy_score(y_true, y_pred)
    f1 = f1_score(y_true, y_pred, average="macro", zero_division=0)
    print("\n--- HW EVALUATION COMPLETE ---")
    print(f"Total seconds = {seconds_total:.2f}")
    print(f"Accuracy = {acc:.4f}, F1 Score = {f1:.4f}")
    if class_names is not None:
        labels = sorted(set(y_true))
        target_names = [class_names[i] for i in labels]
        print("\nClassification Report:")
        print(classification_report(y_true, y_pred, labels=labels,
                                    target_names=target_names, zero_division=0))
    return acc, f1


# ==========================================================
# Utilities
# ==========================================================

def load_model(ckpt_path, num_classes, device):
    """Load a trained DeepSNNClassification_g11 model from checkpoint.

    Args:
        ckpt_path: Path to .pt file.
        num_classes: Number of output classes.
        device: torch device.

    Returns:
        Loaded model in eval mode.
    """
    model = DeepSNNClassification_g11(num_classes=num_classes).to(device)

    if os.path.exists(ckpt_path):
        model.load_state_dict(torch.load(ckpt_path, map_location=device))
        print(f"✅ Model loaded from: {ckpt_path}")
    else:
        print("⚠️ Checkpoint not found – using untrained model.")

    model.eval()
    return model


def build_subset_dataloader(test_dl, subset_size):
    """Create a DataLoader with a subset of the test dataset.

    Args:
        test_dl: Original test DataLoader.
        subset_size: Number of samples to include.

    Returns:
        New DataLoader with the first `subset_size` samples.
    """
    dataset = test_dl.dataset
    subset_size = min(subset_size, len(dataset))
    indices = list(range(subset_size))

    subset = torch.utils.data.Subset(dataset, indices)

    return torch.utils.data.DataLoader(
        subset,
        batch_size=test_dl.batch_size,
        shuffle=False,
        num_workers=0,
        pin_memory=False
    )


def generate_quant_configs(int_bits_list, frac_bits_list):
    """Generate (total_bits, frac_bits) pairs from integer and fractional bit lists.

    Args:
        int_bits_list: List of integer bit widths.
        frac_bits_list: List of fractional bit widths.

    Returns:
        List of tuples (total_bits, frac_bits).
    """
    configs = []
    for i in int_bits_list:
        for f in frac_bits_list:
            configs.append((i + f, f))
    return configs


# ==========================================================
# Main Optimized Evaluation
# ==========================================================

def optimized_quant_test(
    num_frames,
    checkpoint_path,
    subset_size=10,
    int_bits_list=[9, 10],
    frac_bits_list=[8, 9, 10],
    acc_tolerance=0.98,
    run_deep_compare=True,
    run_hw_float=True
):
    """Main evaluation routine: float baseline, deep compare, quantization sweep.

    Args:
        num_frames: Number of frames the model was trained on (used for logging path).
        checkpoint_path: Path to the trained model checkpoint.
        subset_size: Number of samples to use for evaluation.
        int_bits_list: List of integer bit widths to try.
        frac_bits_list: List of fractional bit widths to try.
        acc_tolerance: Minimum accuracy relative to float (e.g., 0.98 = 98%).
        run_deep_compare: Whether to run detailed per‑layer comparison.
        run_hw_float: Whether to evaluate the hardware model without quantization.
    """
    device = "cuda" if torch.cuda.is_available() else "cpu"

    output_dir = f"quantization_logs/Frames:{num_frames}"
    os.makedirs(output_dir, exist_ok=True)
    duration_file = os.path.join(output_dir, "hw_batch_durations.txt")
    results_csv_file = os.path.join(
        output_dir, "quantization_sweep_results.csv")

    NUM_CLASSES = 4
    CLASS_NAMES = [
        'negative_samples',
        'drifting_or_skidding',
        'other_crash',
        'collision'
    ]

    print("\n" + "="*90)
    print(
        f"📦 Preparing subset ({subset_size} samples) for {num_frames} frames")
    print("="*90)

    _, test_dl = fourth_step(batch_size=1)
    subset_dl = build_subset_dataloader(test_dl, subset_size)

    # ------------------------------------------------------
    # Load Model
    # ------------------------------------------------------
    print("\n🤖 Loading model...")
    pt_model = load_model(checkpoint_path, NUM_CLASSES, device)

    # ------------------------------------------------------
    # FLOAT BASELINE
    # ------------------------------------------------------
    print("\n📈 Evaluating FLOAT baseline...")
    float_acc, float_f1 = eval_float_model(
        pt_model,
        subset_dl,
        device,
        CLASS_NAMES
    )

    print(f"✅ Float baseline: Acc={float_acc:.4f}, F1={float_f1:.4f}")

    # ------------------------------------------------------
    # HW WRAPPER (Quant OFF)
    # ------------------------------------------------------
    if run_hw_float:
        print("\n🔬 Evaluating HW wrapper (Quant OFF)...")

        hw_float = CustomQuantizedG11(
            pt_model,
            quantization=False
        )

        start = time.time()
        hw_float_acc, hw_float_f1 = eval_hw_model(
            hw_float,
            subset_dl,
            CLASS_NAMES,
            duration_file=duration_file,
            verbose=False
        )
        print(f"HW Float: Acc={hw_float_acc:.4f}, F1={hw_float_f1:.4f}")
        print(f"Δ Accuracy vs PT: {abs(hw_float_acc - float_acc):.6f}")

    # ------------------------------------------------------
    # DEEP COMPARISON (Optional)
    # ------------------------------------------------------
    if run_deep_compare:
        print("\n🔎 Running deep comparison...")
        hw_float = CustomQuantizedG11(pt_model, quantization=False)

        passed, stats, _, _ = deep_compare_subset(
            pt_model,
            hw_float,
            subset_dl,
            num_samples=subset_size,
            spike_mismatch_threshold=0.02,
            rtol=1e-3,
            atol=1e-3
        )

        print(f"Deep compare: {'✅ PASS' if passed else '❌ FAIL'}")

    # ------------------------------------------------------
    # QUANTIZATION SWEEP
    # ------------------------------------------------------
    print("\n📈 Running quantization sweep...")

    quant_configs = generate_quant_configs(int_bits_list, frac_bits_list)
    results = []

    for total_bits, frac_bits in quant_configs:

        print(f"\n--- total_bits={total_bits}, frac_bits={frac_bits} ---")

        hw_quant = CustomQuantizedG11(
            pt_model,
            quantization=True,
            total_bits=total_bits,
            frac_bits=frac_bits
        )

        start = time.time()
        acc, f1 = eval_hw_model(
            hw_quant,
            subset_dl,
            CLASS_NAMES,
            duration_file=duration_file,
            verbose=False
        )
        elapsed = time.time() - start

        print(f"Acc={acc:.4f} | F1={f1:.4f} | Time={elapsed:.2f}s")

        results.append({
            "total_bits": total_bits,
            "frac_bits": frac_bits,
            "accuracy": acc,
            "f1": f1,
            "time": elapsed
        })

    # Save quantization sweep results to CSV
    with open(results_csv_file, 'w', newline='') as csvfile:
        fieldnames = ["total_bits", "frac_bits", "accuracy", "f1", "time"]
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)
    print(f"Quantization sweep results saved to {results_csv_file}")

    # ------------------------------------------------------
    # SUMMARY
    # ------------------------------------------------------
    print("\n" + "="*90)
    print("📊 SUMMARY")
    print("="*90)

    recommended = None

    for r in sorted(results, key=lambda x: x["total_bits"]):
        acc_ratio = r["accuracy"] / float_acc if float_acc > 0 else 0

        print(
            f"{r['total_bits']:>3} bits | "
            f"frac={r['frac_bits']:>2} | "
            f"Acc={r['accuracy']:.4f} | "
            f"{acc_ratio*100:>6.1f}% of float"
        )

        if acc_ratio >= acc_tolerance and recommended is None:
            recommended = r

    if recommended:
        print(
            f"\n✅ Recommended: {recommended['total_bits']} bits "
            f"(frac={recommended['frac_bits']})"
        )
    else:
        print("\n⚠️ No config meets tolerance.")
        best = max(results, key=lambda x: x["accuracy"])
        print(
            f"Best achieved: {best['total_bits']} bits | Acc={best['accuracy']:.4f}")

    print("\n✨ Evaluation complete.\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description='Run Optimized Quantization Test.')

    # Made 'num_frames' optional so we don't have to provide it just to run verification
    parser.add_argument('num_frames', type=int, nargs='?', default=16,
                        help='Number of frames for which the model was trained.')

    parser.add_argument('--checkpoint_path', type=str,
                        default="checkpoints/Frames:16/student_frames_16_epoch_127_f1_0.7276_acc_0.7490_g11.pt",
                        help='Path to the model checkpoint.')
    parser.add_argument('--subset_size', type=int, default=50,
                        help='Number of samples to use for testing.')
    parser.add_argument('--acc_tolerance', type=float, default=0.98,
                        help='Accuracy tolerance for quantization sweep.')

    # ADDED FLAG FOR HARDWARE VERIFICATION
    parser.add_argument('--verify_stage1', action='store_true',
                        help='Run isolated Stage 1 verification on 256x256 dummy image')

    args = parser.parse_args()

    # Intercept and run verification if flag is passed
    if args.verify_stage1:
        verify_stage1_hardware()
        import sys
        sys.exit(0)

    args = parser.parse_args()
    optimized_quant_test(
        num_frames=args.num_frames,
        checkpoint_path=args.checkpoint_path,
        subset_size=args.subset_size,
        acc_tolerance=args.acc_tolerance
    )
