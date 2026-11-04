/**
 * 下载管理 —— 对应 LibreTV Web 版的分片下载缓存（IndexedDB）
 *
 * 原生实现：拉取（已过滤广告的）m3u8 播放列表 → 顺序下载 .ts 分片到沙箱
 *   → 生成本地 playlist.m3u8 → 离线可通过 fd:// 播放
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { DownloadTaskRecord } from '../model/Types';
import { Store } from './Store';
import { EventBus, Events } from '../common/EventBus';
import { HttpClient, HttpResult } from '../net/HttpClient';
import { PlayUrlResolver } from '../player/PlayUrlResolver';
import { SettingsStore } from './SettingsStore';
import { Utils } from '../common/Utils';
import { ScreenKeeper } from '../common/ScreenKeeper';

interface TaskPatch {
  status?: string;
  done?: number;
  total?: number;
}

export class DownloadManager {
  private static readonly KEY = 'download_tasks';
  private static readonly MAX_TASKS = 50;

  private static inst: DownloadManager | null = null;
  private tasks: DownloadTaskRecord[] = [];
  private active: Set<string> = new Set();
  private cancelled: Set<string> = new Set();
  /**
   * 暂停时点的「继续」先排在这里。
   * 暂停只是置了取消标记，正在 await 的那次分片请求最长还要 25s 才返回，
   * 这段时间 active 里仍有该 id —— 立刻重挂 runTask 会被它自己挡回来，
   * 表现为「点了继续没反应」。所以排队，等 runTask 的 finally 里再拉起。
   */
  private resumeQueue: Set<string> = new Set();
  private appContext: common.Context | null = null;
  /** 累计未落盘的进度更新数，用于节流写盘 */
  private pendingSaves: number = 0;
  /** 卡死看门狗 */
  private watchdog: number = -1;

  static shared(): DownloadManager {
    if (!DownloadManager.inst) {
      DownloadManager.inst = new DownloadManager();
    }
    return DownloadManager.inst;
  }

  /** 由 EntryAbility 注入，用于定位沙箱目录 */
  init(context: common.Context): void {
    this.appContext = context;
    // 应用被系统回收、或安装新包时，后台任务线程会一起消失，
    // 但任务状态还留在 downloading —— 界面上就是一个永远不动的进度条。
    // 这里把没跑完的任务重新拉起来（已落盘的分片会跳过）。
    this.resumeInterrupted();
    this.startWatchdog();
  }

  /**
   * 看门狗：周期检查有没有「状态还在 downloading，但进度长时间不动」的任务。
   *
   * 实测两种断链：一是设备休眠把线程冻住，HttpRequest 的回调再也不回来；
   * 二是请求异常时 Promise 链中断，finally 没跑到。两种表现一样 ——
   * 状态停在 downloading、进度不再增长、界面上就是个假死的进度条。
   * 这里统一按「60 秒没有新进展」判定死亡，重挂一次（已下载的分片会跳过）。
   */
  private startWatchdog(): void {
    if (this.watchdog >= 0) {
      return;
    }
    this.watchdog = setInterval(() => {
      const now: number = Date.now();
      for (const t of this.tasks) {
        if (t.status !== 'downloading' && t.status !== 'merging') {
          continue;
        }
        const url: string = t.episodeUrl !== undefined ? t.episodeUrl : '';
        if (url === '') {
          continue;
        }
        if (now - t.updatedAt < 60000) {
          continue;
        }
        // 先摘掉 active 标记，否则 runTask 会以为它还在跑而直接返回
        this.active.delete(t.id);
        t.updatedAt = now;
        DownloadManager.runTask(t.id, url);
      }
    }, 15000);
  }

  /** 重新拉起上次没跑完的下载任务 */
  resumeInterrupted(): void {
    this.load();
    let changed: boolean = false;
    for (const t of this.tasks) {
      if (t.status !== 'downloading' && t.status !== 'pending' && t.status !== 'merging') {
        if (t.status === 'completed' && !DownloadManager.segReady(DownloadManager.mediaPath(t.dir))) {
          // 老版本「下载完成」的缓存只有 m3u8 + 分片，播放器读不了。
          // 分片还在就地补合并一次，用户不用重新下 900MB。
          if (t.total > 0 && DownloadManager.segReady(t.dir + '/seg_' + PlayUrlResolver.segName(0) + '.ts')) {
            DownloadManager.finalizeTask(t.id);
          }
        }
        continue;
      }
      const url: string = t.episodeUrl !== undefined ? t.episodeUrl : '';
      if (url === '') {
        // 旧版本存下的任务没有原始地址，无法续传。宁可明说中断，
        // 也不要留个「正在下载」把用户骗在这里等。
        t.status = 'failed';
        t.error = '下载已中断，请重新下载';
        changed = true;
        continue;
      }
      DownloadManager.runTask(t.id, url);
    }
    if (changed) {
      this.save();
    }
  }

  getTasks(): DownloadTaskRecord[] {
    this.load();
    // 必须逐字段深拷贝。slice() 只复制数组、不复制元素，页面拿到的仍是
    // 内部那批对象；下载线程 updateTask() 改的就是同一批对象，于是
    // 「上一帧快照」与「当前快照」内容恒等，进度的差异判断永远不成立 →
    // 界面死死停在起始数字（真机表现为磁盘分片已 85，UI 仍显示 2/287）。
    const out: DownloadTaskRecord[] = [];
    for (const t of this.tasks) {
      out.push(DownloadManager.cloneTask(t));
    }
    return out;
  }

  /** 任务记录的逐字段拷贝（含可选字段） */
  static cloneTask(t: DownloadTaskRecord): DownloadTaskRecord {
    const c: DownloadTaskRecord = {
      id: t.id,
      sourceKey: t.sourceKey,
      vodId: t.vodId,
      name: t.name,
      sourceName: t.sourceName,
      episode: t.episode,
      episodeName: t.episodeName,
      status: t.status,
      done: t.done,
      total: t.total,
      dir: t.dir,
      updatedAt: t.updatedAt
    };
    if (t.pic !== undefined) {
      c.pic = t.pic;
    }
    if (t.error !== undefined) {
      c.error = t.error;
    }
    if (t.episodeUrl !== undefined) {
      c.episodeUrl = t.episodeUrl;
    }
    return c;
  }

  /** 把任务状态/进度压成字符串，界面用它判断是否需要重建列表（避免每秒无意义重绘） */
  static progressKey(tasks: DownloadTaskRecord[]): string {
    let key: string = '';
    for (const t of tasks) {
      const status: string = t.status !== undefined ? t.status : '';
      const done: number = t.done !== undefined ? t.done : 0;
      const total: number = t.total !== undefined ? t.total : 0;
      const err: string = t.error !== undefined ? t.error : '';
      key += t.id + '|' + status + '|' + done.toString() + '/' + total.toString() + '|' + err + '\n';
    }
    return key;
  }

  getTask(id: string): DownloadTaskRecord | null {
    this.load();
    for (const t of this.tasks) {
      if (t.id === id) {
        return t;
      }
    }
    return null;
  }

  /** 已下载任务的本地播放列表路径（旧版本留下的文件，仅用于清理） */
  static playlistPath(dir: string): string {
    return dir + '/playlist.m3u8';
  }

  /**
   * 离线播放用的整文件路径。
   *
   * 为什么不是 m3u8：实测 AVPlayer 的 HLS 解复用器读不到播放列表里引用的
   * 沙箱分片 —— file:// 与裸绝对路径都试过，稳定报
   * 5400103 IO Error (HLS_MEDIA_DATA)。分片下载完必须合并成一个整文件，
   * 通过 fd:// 交给播放器才认。
   */
  static mediaPath(dir: string): string {
    return dir + '/video.ts';
  }

  /**
   * 创建并开始一个下载任务。
   * 返回任务 id；已存在同集任务时返回空串。
   */
  start(sourceKey: string, vodId: string, name: string, pic: string | undefined,
        sourceName: string, episode: number, episodeName: string, episodeUrl: string): string {
    this.load();
    for (const t of this.tasks) {
      if (t.sourceKey === sourceKey && t.vodId === vodId && t.episode === episode) {
        if (t.status === 'completed' || t.status === 'downloading' || t.status === 'pending') {
          return '';
        }
        if (t.status === 'failed' || t.status === 'paused') {
          // 失败、中断、暂停后再次点下载：复用原任务与原目录续传，
          // 否则每失败一次就多一个重复条目、多一份残留分片。
          this.cancelled.delete(t.id);
          this.resumeQueue.delete(t.id);
          t.status = 'pending';
          t.error = undefined;
          t.episodeUrl = episodeUrl;
          t.updatedAt = Date.now();
          this.save();
          DownloadManager.runTask(t.id, episodeUrl);
          return t.id;
        }
      }
    }
    const id = Utils.stableId(sourceKey + '|' + vodId + '|' + episode + '|' + Date.now().toString());
    const task: DownloadTaskRecord = {
      id: id,
      sourceKey: sourceKey,
      vodId: vodId,
      name: name,
      pic: pic,
      sourceName: sourceName,
      episode: episode,
      episodeName: episodeName,
      status: 'pending',
      done: 0,
      total: 0,
      dir: DownloadManager.baseDir() + '/' + id,
      updatedAt: Date.now(),
      error: undefined,
      episodeUrl: episodeUrl
    };
    this.tasks.unshift(task);
    if (this.tasks.length > DownloadManager.MAX_TASKS) {
      this.tasks = this.tasks.slice(0, DownloadManager.MAX_TASKS);
    }
    this.save();
    DownloadManager.runTask(id, episodeUrl);
    return id;
  }

  cancel(id: string): void {
    this.load();
    this.cancelled.add(id);
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].id === id && this.tasks[i].status === 'downloading') {
        this.tasks[i].status = 'failed';
        this.tasks[i].error = '已取消';
        break;
      }
    }
    this.save();
  }

  /**
   * 暂停：只置标记，不动磁盘上的分片。
   * 下次继续时 runTask 会按磁盘实际分片数重算进度，从断点接着下。
   */
  pause(id: string): void {
    this.load();
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].id !== id) {
        continue;
      }
      const st: string = this.tasks[i].status;
      if (st !== 'downloading' && st !== 'pending') {
        return;
      }
      this.cancelled.add(id);
      this.tasks[i].status = 'paused';
      this.tasks[i].error = undefined;
      this.tasks[i].updatedAt = Date.now();
      this.save();
      return;
    }
  }

  /** 继续：从已落盘的分片处接着下（已存在的分片会自动跳过） */
  resume(id: string): boolean {
    this.load();
    const t = this.findTask(id);
    if (t === null) {
      return false;
    }
    const url: string = t.episodeUrl !== undefined ? t.episodeUrl : '';
    if (url === '') {
      // 旧版本任务没存原始地址，重下比假装能续传更诚实
      this.failTask(id, '缺少播放地址，请删除后重新下载');
      return false;
    }
    t.status = 'pending';
    t.error = undefined;
    t.updatedAt = Date.now();
    this.save();
    if (this.active.has(id)) {
      this.resumeQueue.add(id);
      return true;
    }
    this.cancelled.delete(id);
    DownloadManager.runTask(id, url);
    return true;
  }

  remove(id: string): void {
    this.load();
    this.cancelled.add(id);
    const next: DownloadTaskRecord[] = [];
    let dir = '';
    for (const t of this.tasks) {
      if (t.id === id) {
        dir = t.dir;
      } else {
        next.push(t);
      }
    }
    this.tasks = next;
    this.save();
    if (dir !== '') {
      DownloadManager.rmDir(dir);
    }
  }

  clearCompleted(): void {
    this.load();
    const next: DownloadTaskRecord[] = [];
    for (const t of this.tasks) {
      if (t.status === 'completed') {
        DownloadManager.rmDir(t.dir);
        continue;
      }
      next.push(t);
    }
    this.tasks = next;
    this.save();
  }

  /** 递归删除目录（fileIo 无 rmSync，手动实现） */
  private static rmDir(dir: string): void {
    try {
      const entries = fs.listFileSync(dir);
      for (const name of entries) {
        const p = dir + '/' + name;
        const st = fs.statSync(p);
        if (st.isDirectory()) {
          DownloadManager.rmDir(p);
        } else {
          fs.unlinkSync(p);
        }
      }
      fs.rmdirSync(dir);
    } catch (e) {
      // ignore
    }
  }

  /** 分片是否已完整落盘（存在且非空） */
  private static segReady(p: string): boolean {
    try {
      return fs.statSync(p).size > 0;
    } catch (e) {
      return false;
    }
  }

  /**
   * 把 0..count-1 号分片按顺序拼成 video.ts。
   * 全程同步 IO，所以每 40 片让出一次事件循环 —— 否则长视频合并时
   * 主线程会被按住几十秒，界面看着像卡死。
   */
  private static async mergeSegments(dir: string, count: number, taskId: string): Promise<boolean> {
    const out: string = DownloadManager.mediaPath(dir);
    let of: fs.File | null = null;
    try {
      of = fs.openSync(out, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const ofd: number = of.fd;
      const chunk: number = 1024 * 1024;
      for (let i = 0; i < count; i++) {
        const p: string = dir + '/seg_' + PlayUrlResolver.segName(i) + '.ts';
        const size: number = fs.statSync(p).size;
        const f: fs.File = fs.openSync(p, fs.OpenMode.READ_ONLY);
        try {
          let off: number = 0;
          while (off < size) {
            const len: number = Math.min(chunk, size - off);
            const buf: ArrayBuffer = new ArrayBuffer(len);
            const read: number = fs.readSync(f.fd, buf, { offset: off, length: len });
            if (read <= 0) {
              break;
            }
            fs.writeSync(ofd, buf, { length: read });
            off += read;
          }
        } finally {
          fs.closeSync(f);
        }
        if (i % 40 === 0) {
          // 大文件合并要几十秒，必须报心跳：
          // 看门狗按「60s 没有新进展」判死，否则会在合并途中把任务重挂，
          // 白白从第 0 片重下一遍 900MB。
          DownloadManager.shared().touchTask(taskId);
          await DownloadManager.sleep(0);
        }
      }
      return true;
    } catch (e) {
      return false;
    } finally {
      if (of !== null) {
        fs.closeSync(of);
      }
    }
  }

  /** 合并完成后删掉分片与旧播放列表，回收空间 */
  private static async dropSegments(dir: string, count: number): Promise<void> {
    for (let i = 0; i < count; i++) {
      try {
        fs.unlinkSync(dir + '/seg_' + PlayUrlResolver.segName(i) + '.ts');
      } catch (e) {
        // 忽略
      }
      if (i % 200 === 0) {
        await DownloadManager.sleep(0);
      }
    }
    try {
      fs.unlinkSync(DownloadManager.playlistPath(dir));
    } catch (e) {
      // 忽略
    }
    // 合并完成后把中断遗留的 .part 一并清掉，别白占空间
    try {
      for (const name of fs.listFileSync(dir)) {
        if (name.endsWith('.part')) {
          try {
            fs.unlinkSync(dir + '/' + name);
          } catch (e2) {
            // 忽略
          }
        }
      }
    } catch (e3) {
      // 忽略
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: (value: void) => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 拉一个分片，并套一层硬超时。
   * http 的 readTimeout 在设备休眠 / 网络切换时可能根本不触发，
   * 让 await 无限挂住；这里用竞速保证一定会返回。
   */
  private static fetchSegment(url: string, headers: Record<string, string>): Promise<HttpResult> {
    return new Promise<HttpResult>((resolve: (value: HttpResult) => void) => {
      let finished: boolean = false;
      const timer: number = setTimeout(() => {
        if (finished) {
          return;
        }
        finished = true;
        resolve({ ok: false, status: 0, text: '', bytes: new Uint8Array(0), error: 'timeout' });
      }, 25000);
      HttpClient.getBytes(url, headers, 20000).then((r: HttpResult) => {
        if (finished) {
          return;
        }
        finished = true;
        clearTimeout(timer);
        resolve(r);
      }).catch(() => {
        if (finished) {
          return;
        }
        finished = true;
        clearTimeout(timer);
        resolve({ ok: false, status: 0, text: '', bytes: new Uint8Array(0), error: 'exception' });
      });
    });
  }

  private static baseDir(): string {
    const ctx = DownloadManager.shared().appContext;
    const root = ctx !== null ? ctx.filesDir : '/data/storage/el1/bundle';
    return root + '/downloads';
  }

  /** 分片已经齐了，只差合并：老缓存补合并走这里 */
  private static async finalizeTask(id: string): Promise<void> {
    const mgr = DownloadManager.shared();
    if (mgr.active.has(id)) {
      return;
    }
    const task = mgr.findTask(id);
    if (task === null) {
      return;
    }
    mgr.active.add(id);
    const total: number = task.total;
    const dir: string = task.dir;
    try {
      mgr.updateTask(id, { status: 'merging' });
      const ok: boolean = await DownloadManager.mergeSegments(dir, total, id);
      if (!ok) {
        mgr.failTask(id, '分片合并失败，请重试');
        return;
      }
      await DownloadManager.dropSegments(dir, total);
      mgr.updateTask(id, { status: 'completed', done: total, total: total });
    } finally {
      mgr.active.delete(id);
    }
  }

  private static async runTask(id: string, episodeUrl: string): Promise<void> {
    const mgr = DownloadManager.shared();
    if (mgr.active.has(id)) {
      return;
    }
    mgr.active.add(id);
    // 下载期间保持屏幕常亮，避免休眠把网络回调冻死
    ScreenKeeper.acquire();
    try {
      const task = mgr.findTask(id);
      if (task === null) {
        return;
      }
      const settings = SettingsStore.shared().get();
      const segs = await PlayUrlResolver.fetchSegments(episodeUrl, settings.adFilter);
      if (mgr.cancelled.has(id)) {
        return;
      }
      if (segs.urls.length === 0) {
        mgr.failTask(id, segs.error !== '' ? segs.error : '未找到分片');
        return;
      }
      const dir = task.dir;
      try {
        fs.mkdirSync(dir, true);
      } catch (e) {
        // 续传时目录必然已存在，mkdirSync 会抛 "File exists"，这里不是错误。
        // 真建不出来，后面写分片自然会失败并给出具体分片号。
      }
      const headers = PlayUrlResolver.headersFor(episodeUrl);
      // 断点续传：目录里已经存在的非空分片直接跳过。
      // 上次进程被杀时下到一半的那些片不必重下，也就不会白等几分钟。
      let already: number = 0;
      for (let i = 0; i < segs.urls.length; i++) {
        if (DownloadManager.segReady(dir + '/seg_' + PlayUrlResolver.segName(i) + '.ts')) {
          already++;
        }
      }
      // 先按磁盘实际进度写一次 done，再把状态标成 downloading，
      // 否则续传瞬间会把已有的几百片显示成 0/xxx。
      mgr.updateTask(id, { status: 'downloading', total: segs.urls.length, done: already });
      let doneBytes = 0;
      // 用独立计数器而不是下标：续传时前面的片可能已存在，
      // 直接写 i+1 会让显示的数字往回跳。
      let doneCount: number = already;
      for (let i = 0; i < segs.urls.length; i++) {
        if (mgr.cancelled.has(id)) {
          return;
        }
        const segPath = dir + '/seg_' + PlayUrlResolver.segName(i) + '.ts';
        if (DownloadManager.segReady(segPath)) {
          continue;
        }
        // 单个分片偶发失败（CDN 抖动、连接被掐）不该直接废掉整条任务：
        // 1313 片里任何一片抖一下，前面几十分钟就白等了。重试 3 次。
        let res: HttpResult = await DownloadManager.fetchSegment(segs.urls[i], headers);
        let attempt: number = 1;
        while (!res.ok && attempt < 3) {
          if (mgr.cancelled.has(id)) {
            return;
          }
          await DownloadManager.sleep(600 * attempt);
          res = await DownloadManager.fetchSegment(segs.urls[i], headers);
          attempt++;
        }
        if (!res.ok) {
          mgr.failTask(id, '分片 ' + (i + 1) + ' 下载失败（已重试 ' + attempt.toString() + ' 次）');
          return;
        }
        // 先写 .part 再原子改名：进程若在 write 中途被系统杀掉，
        // 留下的是 seg_x.ts.part（不会被 segReady 认作完整分片），
        // 下次续传会重下这一片；直接写 seg_x.ts 则半截文件会被当成已完成，
        // 合并出来的整片在那一段就是花屏/卡死。
        const partPath: string = segPath + '.part';
        const file = fs.openSync(partPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, res.bytes.buffer as ArrayBuffer);
        fs.closeSync(file);
        try {
          fs.renameSync(partPath, segPath);
        } catch (e) {
          // 个别文件系统不允许覆盖改名：退化成「删掉旧的再改名」
          try {
            fs.unlinkSync(segPath);
          } catch (e2) {
            // 旧文件不存在，忽略
          }
          fs.renameSync(partPath, segPath);
        }
        doneBytes += res.bytes.length;
        doneCount++;
        mgr.updateTask(id, { done: doneCount, total: segs.urls.length });
      }
      // 合并成一个整文件再交付：AVPlayer 读不到 m3u8 里引用的沙箱分片，
      // 只有整文件才能通过 fd:// 播放。合并完把分片删掉回收空间。
      mgr.updateTask(id, { status: 'merging' });
      const merged: boolean = await DownloadManager.mergeSegments(dir, segs.urls.length, id);
      if (!merged) {
        mgr.failTask(id, '分片合并失败，请重试');
        return;
      }
      await DownloadManager.dropSegments(dir, segs.urls.length);
      mgr.updateTask(id, { status: 'completed', done: segs.urls.length, total: segs.urls.length });
    } catch (e) {
      mgr.failTask(id, '下载异常: ' + e);
    } finally {
      mgr.active.delete(id);
      mgr.cancelled.delete(id);
      ScreenKeeper.release();
      // 暂停期间用户点了「继续」：此刻才算真正退出，可以重挂了
      if (mgr.resumeQueue.has(id)) {
        mgr.resumeQueue.delete(id);
        const again = mgr.findTask(id);
        const againUrl: string = again !== null && again.episodeUrl !== undefined ? again.episodeUrl : '';
        if (again !== null && againUrl !== '' && again.status === 'pending') {
          DownloadManager.runTask(id, againUrl);
        }
      }
    }
  }

  private findTask(id: string): DownloadTaskRecord | null {
    for (const t of this.tasks) {
      if (t.id === id) {
        return t;
      }
    }
    return null;
  }

  /** 只更新心跳时间，不落盘：合并阶段每 40 片调一次，写盘太浪费 */
  private touchTask(id: string): void {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].id === id) {
        this.tasks[i].updatedAt = Date.now();
        return;
      }
    }
  }

  private updateTask(id: string, patch: TaskPatch): void {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].id === id) {
        if (patch.status !== undefined) {
          this.tasks[i].status = patch.status;
        }
        if (patch.done !== undefined) {
          this.tasks[i].done = patch.done;
        }
        if (patch.total !== undefined) {
          this.tasks[i].total = patch.total;
        }
        this.tasks[i].updatedAt = Date.now();
        break;
      }
    }
    // 每下一片都写一次 preferences 太浪费（300 片 = 300 次 JSON 序列化 + 落盘）。
    // 纯进度更新攒 8 片写一次；状态变化（完成 / 失败）立即写。
    // 万一进程被杀导致最后几片进度没存，重启时 resumeInterrupted 会按磁盘
    // 实际分片数重算 done，数值不会偏。
    if (patch.status !== undefined) {
      this.pendingSaves = 0;
      this.save();
      return;
    }
    this.pendingSaves++;
    if (this.pendingSaves >= 8) {
      this.pendingSaves = 0;
      this.save();
    }
  }

  private failTask(id: string, error: string): void {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].id === id) {
        this.tasks[i].status = 'failed';
        this.tasks[i].error = error;
        this.tasks[i].updatedAt = Date.now();
        break;
      }
    }
    this.save();
  }

  private load(): void {
    if (this.tasks.length > 0) {
      return;
    }
    const json = Store.shared().getJson(DownloadManager.KEY);
    if (json === '') {
      return;
    }
    try {
      const arr = JSON.parse(json) as object[];
      if (!Array.isArray(arr)) {
        return;
      }
      for (const item of arr) {
        const rec = item as Record<string, object>;
        this.tasks.push({
          id: DownloadManager.str(rec['id']),
          sourceKey: DownloadManager.str(rec['sourceKey']),
          vodId: DownloadManager.str(rec['vodId']),
          name: DownloadManager.str(rec['name']),
          pic: DownloadManager.optStr(rec['pic']),
          sourceName: DownloadManager.str(rec['sourceName']),
          episode: DownloadManager.num(rec['episode'], 0),
          episodeName: DownloadManager.str(rec['episodeName']),
          status: DownloadManager.str(rec['status']),
          done: DownloadManager.num(rec['done'], 0),
          total: DownloadManager.num(rec['total'], 0),
          dir: DownloadManager.str(rec['dir']),
          updatedAt: DownloadManager.num(rec['updatedAt'], 0),
          error: DownloadManager.optStr(rec['error']),
          episodeUrl: DownloadManager.optStr(rec['episodeUrl'])
        });
      }
    } catch (e) {
      // ignore
    }
  }

  private save(): void {
    Store.shared().putJson(DownloadManager.KEY, JSON.stringify(this.tasks));
    EventBus.emit(Events.DOWNLOADS_CHANGED);
  }

  private static str(v: object): string {
    return typeof v === 'string' ? (v as string) : '';
  }

  private static optStr(v: object): string | undefined {
    return typeof v === 'string' && (v as string) !== '' ? (v as string) : undefined;
  }

  private static num(v: object, def: number): number {
    return typeof v === 'number' ? (v as number) : def;
  }
}
