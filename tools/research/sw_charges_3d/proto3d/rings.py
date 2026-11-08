"""Круговое вихревое кольцо из n звеньев: (середины, α = Γ·dl, σ)."""
import numpy as np


def basis(axis):
    axis = np.asarray(axis, float)
    axis = axis / np.linalg.norm(axis)
    t = np.array([1.0, 0, 0]) if abs(axis[0]) < 0.9 else np.array([0, 1.0, 0])
    e1 = np.cross(axis, t); e1 /= np.linalg.norm(e1)
    e2 = np.cross(axis, e1)
    return e1, e2, axis


def ring_segments(center, axis, a, gamma, core, n=16):
    """Кольцо радиуса a вокруг оси axis (правый винт: скорость на оси — вдоль axis при gamma > 0)."""
    e1, e2, ax = basis(axis)
    th = (np.arange(n) + 0.5) * 2 * np.pi / n
    pos = np.asarray(center, float)[None] + a * (np.cos(th)[:, None] * e1 + np.sin(th)[:, None] * e2)
    tang = -np.sin(th)[:, None] * e1 + np.cos(th)[:, None] * e2
    dl = tang * (2 * np.pi * a / n)
    return pos, gamma * dl, np.full(n, core)


def ring_batch(centers, axes, a, gamma, core, n=16):
    """Много колец одинаковых (a, Γ, core) разом: centers (m,3), axes (m,3) единичные → (pos (m·n,3), α (m·n,3), σ)."""
    axes = axes / np.linalg.norm(axes, axis=1, keepdims=True)
    t = np.where(np.abs(axes[:, :1]) < 0.9, np.array([[1.0, 0, 0]]), np.array([[0, 1.0, 0]]))
    e1 = np.cross(axes, t); e1 /= np.linalg.norm(e1, axis=1, keepdims=True)
    e2 = np.cross(axes, e1)
    th = (np.arange(n) + 0.5) * 2 * np.pi / n
    c, s = np.cos(th)[None, :, None], np.sin(th)[None, :, None]
    pos = centers[:, None, :] + a * (c * e1[:, None, :] + s * e2[:, None, :])
    tang = -s * e1[:, None, :] + c * e2[:, None, :]
    al = gamma * tang * (2 * np.pi * a / n)
    return pos.reshape(-1, 3), al.reshape(-1, 3), np.full(centers.shape[0] * n, core)
