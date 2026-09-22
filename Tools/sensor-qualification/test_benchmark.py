import unittest

import benchmark


class FixtureShapeTests(unittest.TestCase):
    def test_raw_shapes_and_digest_input_are_repeatable(self):
        for kind, counts, size in ((1, 7200, 23110), (4, 180000, 366010)):
            for entropy in ("periodic", "random"):
                raw, declared = benchmark.fixture(kind, entropy)
                self.assertEqual((declared, len(raw)), (counts, size))
                self.assertEqual(benchmark.validate_container(raw), counts)
                self.assertEqual(raw, benchmark.fixture(kind, entropy)[0])

    def test_corrupt_identity_shape_and_trailing_bytes_are_rejected(self):
        raw, _ = benchmark.fixture(4, "periodic")
        for offset in (0, 10, 18, 26):
            changed = bytearray(raw)
            changed[offset] ^= 1
            with self.assertRaises(ValueError):
                benchmark.validate_container(changed)
        with self.assertRaises(ValueError):
            benchmark.validate_container(raw + b"x")


if __name__ == "__main__":
    unittest.main()
