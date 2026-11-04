/**
 * 本地回环 HTTP 服务：把沙箱里的离线视频喂给 AVPlayer。
 *
 * 为什么必须这样：
 *  - HLS 播放列表里引用沙箱分片（file:// 与裸绝对路径都试过）→ 5400103 IO Error；
 *  - fd://  交给播放器，没有文件名/扩展名 → 5400106 CONTAINER_ERR 认不出容器；
 *  - file:// 直接给路径 → 连初始化都过不去（播放器进程访问不到应用沙箱）。
 * 播放器唯一稳定能读的就是 http(s)，所以起一个只听 127.0.0.1 的小服务，
 * 把整文件按 Range 请求喂出去。
 */

import { socket } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/** 单条连接的存活标记：客户端一断开就立刻停止推流 */
class ConnState {
  closed: boolean = false;
  client: socket.TCPSocketConnection | null = null;
  /** 连接建立时刻：用来判断谁是「最新那个请求」 */
  bornAt: number = 0;
}

export class LocalHttpServer {
  private static inst: LocalHttpServer | null = null;
  private server: socket.TCPSocketServer | null = null;
  private port: number = 0;
  private file: string = '';
  /**
   * 当前唯一在推流的连接。
   * 播放器每次 seek / 重建播放器都会新开一条连接，旧的那条在我们这边往往还没
   * 感知到 FIN。两条流并行推同一个文件，等于把主线程的喂数据预算分成两半，
   * 结果两条都喂不饱 —— 表现就是「声音在走、画面卡住」。
   * 所以新请求一到就把旧连接掐掉：播放器只关心最新那条。
   */
  private active: ConnState | null = null;

  static shared(): LocalHttpServer {
    if (!LocalHttpServer.inst) {
      LocalHttpServer.inst = new LocalHttpServer();
    }
    return LocalHttpServer.inst;
  }

  /** 启动（或复用）服务，返回可交给播放器的地址；失败返回空串 */
  async mediaUrl(filePath: string): Promise<string> {
    if (this.server !== null && this.file === filePath && this.port > 0) {
      return 'http://127.0.0.1:' + this.port + '/media.ts';
    }
    await this.stop();
    this.file = filePath;
    for (let p = 18211; p <= 18221; p++) {
      const srv = socket.constructTCPSocketServerInstance();
      try {
        await srv.listen({ address: '127.0.0.1', port: p, family: 1 });
      } catch (e) {
        continue;
      }
      this.server = srv;
      this.port = p;
      srv.on('connect', (client: socket.TCPSocketConnection) => {
        this.handle(client);
      });
      return 'http://127.0.0.1:' + p + '/media.ts';
    }
    return '';
  }

  async stop(): Promise<void> {
    const srv = this.server;
    this.server = null;
    this.port = 0;
    if (srv !== null) {
      try {
        srv.close();
      } catch (e) {
        // 忽略
      }
    }
  }

  /** 收到连接后逐块收请求头，凑够 \r\n\r\n 就回响应 */
  private handle(client: socket.TCPSocketConnection): void {
    let buf = new Uint8Array(0);
    let answered = false;
    const state = new ConnState();
    state.client = client;
    state.bornAt = Date.now();
    // 客户端一断开必须立刻停止推流。
    // 播放器每 seek / 换集 / 重建播放器都会关连接，旧实现对着一个死 socket
    // 继续把整个文件读完、推完，主线程被同步 IO 和成批失败的 send 按住，
    // 外部表现就是「画面冻住、声音还在响，拖一下进度条才恢复」。
    client.on('close', () => {
      state.closed = true;
    });
    client.on('error', () => {
      state.closed = true;
    });
    client.on('message', (info: socket.SocketMessageInfo) => {
      if (answered || state.closed) {
        return;
      }
      const chunk = new Uint8Array(info.message);
      if (buf.length + chunk.length > 32768) {
        answered = true;
        LocalHttpServer.closeQuietly(client);
        return;
      }
      const merged = new Uint8Array(buf.length + chunk.length);
      merged.set(buf, 0);
      merged.set(chunk, buf.length);
      buf = merged;
      const head = LocalHttpServer.headText(buf);
      if (head.indexOf('\r\n\r\n') < 0) {
        return;
      }
      answered = true;
      this.respond(client, head, state);
    });
  }

  /** 只解 ASCII 请求头（不依赖 TextDecoder，够用且没有 API 版本差异） */
  private static headText(buf: Uint8Array): string {
    let out = '';
    for (let i = 0; i < buf.length; i++) {
      const c = buf[i];
      if (c === 0) {
        break;
      }
      out += String.fromCharCode(c);
    }
    return out;
  }

  private async respond(client: socket.TCPSocketConnection, head: string, state: ConnState): Promise<void> {
    // 新请求优先：先把上一条还在推的流掐掉（见 active 的注释）。
    // 必须在写响应头之前做，否则旧连接会继续抢主线程时间片。
    const prev: ConnState | null = this.active;
    if (prev !== null && prev !== state) {
      prev.closed = true;
      if (prev.client !== null) {
        LocalHttpServer.closeQuietly(prev.client);
      }
    }
    this.active = state;
    const lines: string[] = head.split('\r\n');
    let start: number = -1;
    let end: number = -1;
    for (const h of lines) {
      const lower: string = h.toLowerCase();
      if (lower.startsWith('range:')) {
        const v: string = h.substring(6).trim();
        const eq: number = v.indexOf('=');
        const spec: string = eq >= 0 ? v.substring(eq + 1) : v;
        const dash: number = spec.indexOf('-');
        if (dash >= 0) {
          const s: string = spec.substring(0, dash);
          const e: string = spec.substring(dash + 1);
          start = s !== '' ? Number.parseInt(s, 10) : 0;
          end = e !== '' ? Number.parseInt(e, 10) : -1;
        }
      }
    }
    let size: number = 0;
    try {
      // 异步取文件大小：statSync 虽小，但也在主线程上做一次系统调用，
      // 播放器频繁 seek 时会被放大成可感知的顿挫。
      const st: fs.Stat = await fs.stat(this.file);
      size = st.size;
    } catch (e) {
      size = 0;
    }
    if (size <= 0) {
      await this.writeAll(client, LocalHttpServer.ascii(
        'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'), state);
      LocalHttpServer.closeQuietly(client);
      return;
    }
    const from: number = start >= 0 ? start : 0;
    let to: number = end >= 0 ? end : size - 1;
    if (to > size - 1) {
      to = size - 1;
    }
    const len: number = to - from + 1;
    let header: string = '';
    if (start >= 0) {
      header = 'HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp2t\r\nContent-Length: ' +
        len.toString() + '\r\nContent-Range: bytes ' + from.toString() + '-' + to.toString() +
        '/' + size.toString() + '\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n';
    } else {
      header = 'HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: ' +
        len.toString() + '\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n';
    }
    const headOk: boolean = await this.writeAll(client, LocalHttpServer.ascii(header), state);
    if (!headOk) {
      LocalHttpServer.closeQuietly(client);
      return;
    }

    let f: fs.File | null = null;
    try {
      // 异步 open / read：readSync 跑在主线程上，读几百 MB 的缓存文件时
      // 会连带把渲染帧和触摸事件一起按住。
      f = await fs.open(this.file, fs.OpenMode.READ_ONLY);
      const fd: number = f.fd;
      // 块从 128KB 降到 64KB：单次占用的主线程时间更短，
      // 也更接近「一块数据 ≈ 一帧的时间预算」，渲染线程不会被挤掉。
      const chunk: number = 64 * 1024;
      let off: number = from;
      while (off <= to && !state.closed) {
        const n: number = Math.min(chunk, to - off + 1);
        const buf: ArrayBuffer = new ArrayBuffer(n);
        const read: number = await fs.read(fd, buf, { offset: off, length: n });
        if (read <= 0) {
          break;
        }
        // read 返回的字节数可能小于 n（文件尾 / 被截断），多出来的那截是未初始化内存，
        // 原样发出去会让播放器解析到垃圾数据，直接按实际长度截断。
        const out: ArrayBuffer = read === n ? buf : buf.slice(0, read);
        const ok: boolean = await this.writeAll(client, out, state);
        if (!ok) {
          // 对端已断开或写失败：立刻停，别把剩下的字节空推一遍
          break;
        }
        off += read;
        // 每一块都让出一次「宏任务」。
        // 之前是每 8 块（=1MB）才让一次，遇到大文件时这一段连续 await
        // 全在微任务队列里打转，事件循环里排着的渲染帧 / 触摸事件一直轮不到 ——
        // 现场就是「画面卡住、声音还在走」。改成逐块 yield，
        // 单次占用压到毫秒级，渲染线程永远有插队的机会。
        // 代价是吞吐被 setTimeout(0) 的调度粒度限制（约 10~20MB/s），
        // 而离线播放的实际码率通常只有 1~3MB/s，余量足够。
        await LocalHttpServer.yieldOnce();
      }
    } catch (e) {
      // 读失败就让客户端断开
    } finally {
      // 这条流结束（正常推完 / 被顶掉 / 出错）都要让出「当前活跃连接」的位置，
      // 否则下一个请求会去关一个早就没人用的句柄。
      if (this.active === state) {
        this.active = null;
      }
      if (f !== null) {
        try {
          await fs.close(f);
        } catch (e) {
          // 忽略
        }
      }
    }
    LocalHttpServer.closeQuietly(client);
  }

  /** 发送一块数据；返回 false 表示这条连接已经不可用，外层应立即停止推流 */
  private writeAll(client: socket.TCPSocketConnection, data: ArrayBuffer, state: ConnState): Promise<boolean> {
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      if (state.closed) {
        resolve(false);
        return;
      }
      client.send({ data: data }).then(() => {
        resolve(!state.closed);
      }).catch(() => {
        resolve(false);
      });
    });
  }

  /** 让出一次宏任务，给渲染帧和触摸事件留出执行机会 */
  private static yieldOnce(): Promise<void> {
    return new Promise<void>((resolve: (value: void) => void) => {
      setTimeout(() => {
        resolve();
      }, 0);
    });
  }

  private static closeQuietly(client: socket.TCPSocketConnection): void {
    try {
      client.close();
    } catch (e) {
      // 忽略
    }
  }

  private static ascii(text: string): ArrayBuffer {
    const buf = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) {
      buf[i] = text.charCodeAt(i) & 0xFF;
    }
    return buf.buffer as ArrayBuffer;
  }
}
