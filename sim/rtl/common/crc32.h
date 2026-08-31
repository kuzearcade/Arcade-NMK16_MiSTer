// Standard IEEE 802.3 / zlib-compatible CRC32, matching the pure-Lua
// implementation in sim/oracle/trace.lua byte-for-byte so frame checksums
// computed on the RTL side are directly comparable to the MAME oracle's.
// Verified against the standard check value CRC32("123456789") = 0xCBF43926
// (same vector used to validate the Lua side against Python's zlib.crc32).
#pragma once

#include <cstdint>
#include <cstddef>

class Crc32 {
public:
	Crc32() {
		for (uint32_t i = 0; i < 256; i++) {
			uint32_t c = i;
			for (int k = 0; k < 8; k++)
				c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
			table[i] = c;
		}
	}

	uint32_t compute(const uint8_t *data, size_t len) const {
		uint32_t crc = 0xFFFFFFFFu;
		for (size_t i = 0; i < len; i++)
			crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
		return crc ^ 0xFFFFFFFFu;
	}

private:
	uint32_t table[256];
};
