from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Metrics:
    fps: float
    infer_ms_avg: float
    latency_avg: float


class RollingWindow:
    def __init__(self) -> None:
        self.count = 0
        self.sum = 0.0
        self.min_v = 10**9
        self.max_v = 0.0

    def add(self, value: float) -> None:
        self.count += 1
        self.sum += float(value)
        if value < self.min_v:
            self.min_v = float(value)
        if value > self.max_v:
            self.max_v = float(value)

    @property
    def avg(self) -> float:
        if self.count <= 0:
            return 0.0
        return self.sum / float(self.count)
