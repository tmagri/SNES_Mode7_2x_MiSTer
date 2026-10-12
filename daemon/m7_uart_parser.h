// m7_uart_parser.h — incremental framing parser for the m7_reg_stream UART
// channel (FPGA -> ARM over /dev/ttyS1).
//
// Frame layout (little-endian, mirrors rtl/m7_reg_stream.sv):
//   A5 5C seq_l seq_h len_l len_h payload[0..len-1] crc8
// crc8 (poly 0x07) covers seq..payload, NOT the sync bytes.
//
// Semantics of the counters, matching scripts/m7_uart_check.py:
//   frames   — completed frames (crc_ok or not)
//   resyncs  — abandoned frames: a accepted-looking header whose len is
//              out of range. Noise bytes while hunting are NOT resyncs.
//   crc_bad  — completed frames whose CRC did not validate.
// A frame truncated by end-of-stream is not counted at all (the parser
// just stays mid-frame waiting for more bytes).
//
// The payload pointer handed to feed()'s out parameter points into the
// caller's own byte stream position history — i.e. it is only valid until
// the next feed() call if the caller copies bytes through a ring; the
// daemon copies payloads out immediately, so a plain pointer is fine.

#ifndef M7_UART_PARSER_H
#define M7_UART_PARSER_H

#include <stdint.h>

enum { M7_UART_MAX_PAYLOAD = 1024 };

struct m7_uart_frame {
	uint16_t seq;
	uint16_t len;
	const uint8_t *payload; // len bytes, valid until the next feed()
	uint8_t crc_rx;
	uint8_t crc_calc;
	int crc_ok;
};

class M7UartParser {
public:
	M7UartParser() { reset(); }

	void reset()
	{
		state_ = ST_SYNC0;
		got_ = 0;
		frames_ = 0;
		resyncs_ = 0;
		crc_bad_ = 0;
	}

	uint32_t frames() const { return frames_; }
	uint32_t resyncs() const { return resyncs_; }
	uint32_t crc_bad() const { return crc_bad_; }

	// Feed one byte. Returns true exactly once per completed frame, with
	// *out filled in. out may be null (counters still advance).
	bool feed(uint8_t b, m7_uart_frame *out)
	{
		switch (state_) {
		case ST_SYNC0:
			if (b == 0xA5)
				state_ = ST_SYNC1;
			return false;

		case ST_SYNC1:
			if (b == 0x5C) {
				state_ = ST_HDR;
				got_ = 0;
			} else if (b == 0xA5) {
				/* stay: this may be the first sync of the next frame */
			} else {
				state_ = ST_SYNC0;
			}
			return false;

		case ST_HDR:
			hdr_[got_++] = b;
			if (got_ < 4)
				return false;
			seq_ = (uint16_t)(hdr_[0] | (hdr_[1] << 8));
			len_ = (uint16_t)(hdr_[2] | (hdr_[3] << 8));
			if (len_ > M7_UART_MAX_PAYLOAD) {
				// bogus header (bit error in a len byte) — abandon
				resyncs_++;
				state_ = ST_SYNC0;
				return false;
			}
			crc_ = crc8_byte(crc8_byte(0, hdr_[0]), hdr_[1]);
			crc_ = crc8_byte(crc8_byte(crc_, hdr_[2]), hdr_[3]);
			got_ = 0;
			state_ = len_ ? ST_PAY : ST_CRC;
			return false;

		case ST_PAY:
			payload_[got_++] = b;
			crc_ = crc8_byte(crc_, b);
			if (got_ < len_)
				return false;
			got_ = 0;
			state_ = ST_CRC;
			return false;

		case ST_CRC:
			state_ = ST_SYNC0;
			frames_++;
			crc_rx_ = b;
			if (out) {
				out->seq     = seq_;
				out->len     = len_;
				out->payload = payload_;
				out->crc_rx  = b;
				out->crc_calc = crc_;
				out->crc_ok  = (b == crc_);
			}
			if (b != crc_) {
				crc_bad_++;
				return false;
			}
			return true;
		}
		return false;
	}

private:
	enum { ST_SYNC0, ST_SYNC1, ST_HDR, ST_PAY, ST_CRC };

	static uint8_t crc8_byte(uint8_t c, uint8_t b)
	{
		c ^= b;
		for (int i = 0; i < 8; i++)
			c = (c & 0x80) ? (uint8_t)((c << 1) ^ 0x07)
				       : (uint8_t)(c << 1);
		return c;
	}

	int      state_;
	uint8_t  hdr_[4];
	uint8_t  payload_[M7_UART_MAX_PAYLOAD];
	uint8_t  crc_;
	uint8_t  crc_rx_;
	uint16_t seq_;
	uint16_t len_;
	int      got_;
	uint32_t frames_;
	uint32_t resyncs_;
	uint32_t crc_bad_;
};

#endif // M7_UART_PARSER_H
