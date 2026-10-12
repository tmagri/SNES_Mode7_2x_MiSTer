// Host-side test for m7_uart_parser.h — feeds a raw capture file through
// the parser and reports the same statistics as scripts/m7_uart_check.py.
//
//   make test CAP=/tmp/m7tb/uart_cap.bin
//
// Exits 1 if no frame validated (capture empty or parser broken), so it
// can gate scripted flows; slip/CRC counts are reported for judgement.

#include "m7_uart_parser.h"

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: test_uart_parser <capture.bin>\n");
		return 2;
	}
	FILE *f = fopen(argv[1], "rb");
	if (!f) {
		perror(argv[1]);
		return 2;
	}

	M7UartParser p;
	m7_uart_frame fr;
	uint8_t buf[4096];
	size_t n;
	uint32_t ok = 0, bytes = 0;
	uint16_t last_seq = 0;
	int have_last = 0;
	uint32_t slips = 0;
	uint16_t first_seq = 0, last_seq_raw = 0;

	while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
		for (size_t i = 0; i < n; i++) {
			bytes++;
			if (p.feed(buf[i], &fr)) {
				ok++;
				if (!have_last) {
					first_seq = fr.seq;
					have_last = 1;
				} else if ((uint16_t)(fr.seq - last_seq) != 1) {
					slips++;
				}
				last_seq = fr.seq;
				last_seq_raw = fr.seq;
			}
		}
	}
	fclose(f);

	printf("bytes=%u frames=%u crc_ok=%u crc_bad=%u resyncs=%u seq_slips=%u\n",
	       (unsigned)bytes, p.frames(), ok, p.crc_bad(), p.resyncs(), slips);
	if (have_last)
		printf("seq: first=%u last=%u span=%u\n", first_seq, last_seq_raw,
		       (uint16_t)(last_seq_raw - first_seq) + 1);
	return ok ? 0 : 1;
}
