import { PushProtocolError } from './registry.ts';

/** Frame/block envelope guard before fzstd allocates its history buffer. It does not decode
 * compressed blocks or assert content validity; the decoder and SHA verifier do that. Handles
 * concatenated frames too, so a small first frame cannot hide an oversized second window. */
export class ZstdBounds {
  private phase: 'frame' | 'block' | 'data' | 'checksum' = 'frame';
  private header: number[] = [];
  private remaining = 0;
  private checksum = false;
  private last = false;
  private frames = 0;
  constructor(private readonly maxOutput: number, private readonly maxWindow = 32 * 1024 * 1024) {}

  push(bytes: Uint8Array) {
    let offset = 0;
    const fail = (code: string): never => { throw new PushProtocolError(code, 409); };
    while (offset < bytes.length) {
      if (this.phase === 'data' || this.phase === 'checksum') {
        const take = Math.min(this.remaining, bytes.length-offset);
        offset += take; this.remaining -= take;
        if (this.remaining) continue;
        if (this.phase === 'checksum') this.phase = 'frame';
        else if (!this.last) this.phase = 'block';
        else if (this.checksum) { this.phase = 'checksum'; this.remaining = 4; }
        else this.phase = 'frame';
        continue;
      }
      this.header.push(bytes[offset++]);
      if (this.phase === 'block') {
        if (this.header.length < 3) continue;
        const value = this.header[0] | this.header[1]<<8 | this.header[2]<<16;
        const type = (value >> 1)&3;
        const size = value >> 3;
        if (type === 3 || size > 131072) fail('invalid_compressed_object');
        this.last = Boolean(value & 1);
        this.remaining = type === 1 ? 1 : size;
        this.phase = 'data'; this.header = [];
        // Empty last blocks do not need a subsequent byte to transition.
        if (!this.remaining) {
          this.phase = !this.last ? 'block' : this.checksum ? 'checksum' : 'frame';
          if (this.phase === 'checksum') this.remaining = 4;
        }
        continue;
      }
      if (this.header.length < 5) continue;
      const h = this.header;
      if (h[0] !== 0x28 || h[1] !== 0xb5 || h[2] !== 0x2f || h[3] !== 0xfd || (h[4] & 0x18)) fail('invalid_compressed_object');
      const single = Boolean(h[4] & 0x20), flag = h[4] >> 6, dictFlag = h[4]&3;
      const dictBytes = dictFlag === 3 ? 4 : dictFlag;
      const sizeBytes = flag ? 1 << flag : single ? 1 : 0;
      const sizeOffset = 5 + (single ? 0 : 1) + dictBytes;
      if (h.length < sizeOffset + sizeBytes) continue;
      if (dictBytes && h.slice(sizeOffset-dictBytes,sizeOffset).some((b) => b !== 0)) fail('unsupported_zstd_dictionary');
      let size = 0;
      for (let i = sizeBytes-1; i >= 0; i--) size = size*256 + h[sizeOffset+i];
      if (flag === 1) size += 256;
      const base = single ? size : 2 ** (10 + (h[5] >> 3));
      const window = single ? size : base + (base/8)*(h[5]&7);
      if (!Number.isSafeInteger(size) || size > this.maxOutput) fail('decoded_size_mismatch');
      if (window > this.maxWindow) fail('zstd_window_too_large');
      this.checksum = Boolean(h[4]&4);
      this.phase = 'block'; this.header = []; this.frames++;
    }
  }
  finish() {
    if (!this.frames || this.phase !== 'frame' || this.header.length) throw new PushProtocolError('invalid_compressed_object', 409);
  }
}
