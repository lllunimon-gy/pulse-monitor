import copy
import unittest
from compare_benchmarks import compare


class BenchmarkComparisonTests(unittest.TestCase):
    def record(self, samples=None):
        # Synthetic fixtures only; these are not Pulse performance measurements.
        return {
            "context": {"device": "fixture-device", "os": "fixture-os", "configuration": "Release",
                        "scenario": "fixture", "monitoring": "50ms", "input_size": "100",
                        "toolchain": "fixture-toolchain"},
            "metric": "latency", "unit": "ms", "commit": "1234567",
            "raw_artifact": "synthetic-unit-test", "samples": samples or [100, 100, 100, 100, 100]
        }

    def test_regression_and_outlier_robustness(self):
        self.assertFalse(compare(self.record(), self.record([100, 100, 100, 100, 999]))["regression"])
        self.assertTrue(compare(self.record(), self.record([120] * 5))["regression"])

    def test_refuses_different_device_or_units(self):
        baseline = self.record()
        candidate = copy.deepcopy(baseline)
        candidate["context"]["device"] = "another-device"
        with self.assertRaises(ValueError):
            compare(baseline, candidate)
        candidate = self.record()
        candidate["unit"] = "seconds"
        with self.assertRaises(ValueError):
            compare(baseline, candidate)

    def test_refuses_insufficient_invalid_and_debug_samples(self):
        for samples in ([1] * 4, [float("nan")] * 5, [-1] * 5, [True] * 5):
            with self.assertRaises(ValueError):
                compare(self.record(), self.record(samples))
        candidate = self.record()
        candidate["context"]["configuration"] = "Debug"
        with self.assertRaises(ValueError):
            compare(self.record(), candidate)

    def test_zero_baseline_needs_explicit_absolute_budget(self):
        self.assertTrue(compare(self.record([0] * 5), self.record([1] * 5))["regression"])
        result = compare(self.record([0] * 5), self.record([1] * 5), absolute_budget=1)
        self.assertFalse(result["regression"])
        self.assertIsNone(result["relative_change"])

    def test_rejects_nonfinite_budget(self):
        with self.assertRaises(ValueError):
            compare(self.record(), self.record(), relative_budget=float("inf"))


if __name__ == "__main__":
    unittest.main()
