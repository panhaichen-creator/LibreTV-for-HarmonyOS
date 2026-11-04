/**
 * 纯 ArkTS 实现的 DEFLATE / GZIP 解压（无第三方依赖）。
 * 用途：解压 XMLTV 节目单（.xml.gz）、带 Content-Encoding: gzip 的 HTTP 响应。
 * 算法参考 zlib puff.c。
 */

import { util } from '@kit.ArkTS';

class BitReader {
  private data: Uint8Array;
  private pos: number = 0;
  private bitBuf: number = 0;
  private bitCnt: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  bits(n: number): number {
    while (this.bitCnt < n) {
      if (this.pos >= this.data.length) {
        throw new Error('deflate stream unexpected end');
      }
      this.bitBuf |= this.data[this.pos] << this.bitCnt;
      this.pos++;
      this.bitCnt += 8;
    }
    const value = this.bitBuf & ((1 << n) - 1);
    this.bitBuf >>>= n;
    this.bitCnt -= n;
    return value;
  }

  alignByte(): void {
    this.bitBuf = 0;
    this.bitCnt = 0;
  }

  get bytePos(): number {
    return this.pos;
  }

  skipTo(pos: number): void {
    this.pos = pos;
    this.bitBuf = 0;
    this.bitCnt = 0;
  }
}

class HuffmanTable {
  private counts: Int32Array;
  private symbols: Int32Array;

  constructor(lengths: Uint8Array) {
    const counts = new Int32Array(16);
    for (let i = 0; i < lengths.length; i++) {
      counts[lengths[i]]++;
    }
    counts[0] = 0;
    const offsets = new Int32Array(16);
    for (let len = 1; len < 16; len++) {
      offsets[len] = offsets[len - 1] + counts[len - 1];
    }
    const symbols = new Int32Array(lengths.length);
    for (let i = 0; i < lengths.length; i++) {
      if (lengths[i] !== 0) {
        symbols[offsets[lengths[i]]] = i;
        offsets[lengths[i]]++;
      }
    }
    this.counts = counts;
    this.symbols = symbols;
  }

  decode(reader: BitReader): number {
    let code = 0;
    let first = 0;
    let index = 0;
    for (let len = 1; len <= 15; len++) {
      code |= reader.bits(1);
      const count = this.counts[len];
      if (code - first < count) {
        return this.symbols[index + (code - first)];
      }
      index += count;
      first += count;
      first <<= 1;
      code <<= 1;
    }
    throw new Error('invalid huffman code');
  }
}

export class Inflate {
  private static readonly LEN_BASE: number[] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
  private static readonly LEN_EXTRA: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
  private static readonly DIST_BASE: number[] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
  private static readonly DIST_EXTRA: number[] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

  static inflate(data: Uint8Array): Uint8Array {
    const reader = new BitReader(data);
    const chunks: Uint8Array[] = [];
    let total = 0;
    for (;;) {
      const bfinal = reader.bits(1);
      const btype = reader.bits(2);
      if (btype === 0) {
        reader.alignByte();
        const p = reader.bytePos;
        const len = data[p] | (data[p + 1] << 8);
        const block = data.subarray(p + 4, p + 4 + len);
        chunks.push(block);
        total += block.length;
        reader.skipTo(p + 4 + len);
      } else if (btype === 1 || btype === 2) {
        let litTable: HuffmanTable;
        let distTable: HuffmanTable;
        if (btype === 1) {
          litTable = new HuffmanTable(Inflate.fixedLitLengths());
          distTable = new HuffmanTable(Inflate.fixedDistLengths());
        } else {
          const hlit = reader.bits(5) + 257;
          const hdist = reader.bits(5) + 1;
          const hclen = reader.bits(4) + 4;
          const order: number[] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
          const codeLengths = new Uint8Array(19);
          for (let i = 0; i < hclen; i++) {
            codeLengths[order[i]] = reader.bits(3);
          }
          const codeTable = new HuffmanTable(codeLengths);
          const lengths = new Uint8Array(hlit + hdist);
          let i = 0;
          while (i < hlit + hdist) {
            const sym = codeTable.decode(reader);
            if (sym < 16) {
              lengths[i] = sym;
              i++;
            } else if (sym === 16) {
              const prev = lengths[i - 1];
              let repeat = 3 + reader.bits(2);
              while (repeat > 0 && i < hlit + hdist) {
                lengths[i] = prev;
                i++;
                repeat--;
              }
            } else if (sym === 17) {
              let repeat = 3 + reader.bits(3);
              while (repeat > 0 && i < hlit + hdist) {
                lengths[i] = 0;
                i++;
                repeat--;
              }
            } else if (sym === 18) {
              let repeat = 11 + reader.bits(7);
              while (repeat > 0 && i < hlit + hdist) {
                lengths[i] = 0;
                i++;
                repeat--;
              }
            } else {
              throw new Error('invalid code length symbol');
            }
          }
          litTable = new HuffmanTable(lengths.subarray(0, hlit));
          distTable = new HuffmanTable(lengths.subarray(hlit));
        }
        const block: number[] = [];
        for (;;) {
          const sym = litTable.decode(reader);
          if (sym === 256) {
            break;
          }
          if (sym < 256) {
            block.push(sym);
          } else {
            const li = sym - 257;
            if (li >= 29) {
              throw new Error('invalid length symbol');
            }
            const length = Inflate.LEN_BASE[li] + reader.bits(Inflate.LEN_EXTRA[li]);
            const dsym = distTable.decode(reader);
            if (dsym >= 30) {
              throw new Error('invalid distance symbol');
            }
            const dist = Inflate.DIST_BASE[dsym] + reader.bits(Inflate.DIST_EXTRA[dsym]);
            const start = block.length - dist;
            if (start < 0) {
              throw new Error('invalid back reference');
            }
            for (let k = 0; k < length; k++) {
              block.push(block[start + k]);
            }
          }
        }
        const blockBytes = new Uint8Array(block.length);
        for (let k = 0; k < block.length; k++) {
          blockBytes[k] = block[k];
        }
        chunks.push(blockBytes);
        total += blockBytes.length;
      } else {
        throw new Error('invalid deflate block type');
      }
      if (bfinal === 1) {
        break;
      }
    }
    const out = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      out.set(chunk, offset);
      offset += chunk.length;
    }
    return out;
  }

  private static fixedLitLengths(): Uint8Array {
    const lengths = new Uint8Array(288);
    for (let i = 0; i < 144; i++) {
      lengths[i] = 8;
    }
    for (let i = 144; i < 256; i++) {
      lengths[i] = 9;
    }
    for (let i = 256; i < 280; i++) {
      lengths[i] = 7;
    }
    for (let i = 280; i < 288; i++) {
      lengths[i] = 8;
    }
    return lengths;
  }

  private static fixedDistLengths(): Uint8Array {
    const lengths = new Uint8Array(30);
    for (let i = 0; i < 30; i++) {
      lengths[i] = 5;
    }
    return lengths;
  }
}

export class Gzip {
  /** 解压 gzip 字节流（自动识别，非 gzip 时原样返回） */
  static gunzip(data: Uint8Array): Uint8Array {
    if (data.length < 18 || data[0] !== 0x1f || data[1] !== 0x8b) {
      throw new Error('not a gzip stream');
    }
    if (data[2] !== 8) {
      throw new Error('unsupported compression method');
    }
    const flg = data[3];
    let pos = 10;
    if ((flg & 0x04) !== 0) {
      const xlen = data[pos] | (data[pos + 1] << 8);
      pos += 2 + xlen;
    }
    if ((flg & 0x08) !== 0) {
      while (pos < data.length && data[pos] !== 0) {
        pos++;
      }
      pos++;
    }
    if ((flg & 0x10) !== 0) {
      while (pos < data.length && data[pos] !== 0) {
        pos++;
      }
      pos++;
    }
    if ((flg & 0x02) !== 0) {
      pos += 2;
    }
    if (pos >= data.length) {
      throw new Error('bad gzip header');
    }
    return Inflate.inflate(data.subarray(pos));
  }

  static toText(bytes: Uint8Array): string {
    const decoder = util.TextDecoder.create('utf-8');
    // slice() 得到独立 buffer，避免 subarray 视图带入无关字节
    const copy = bytes.slice();
    return decoder.decodeToString(copy);
  }
}
