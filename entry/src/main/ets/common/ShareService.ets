/**
 * 系统分享（Share Kit）：把影片以「带封面的超链接」分享出去。
 *
 * 关键约束（来自 SDK 的 @hms.collaboration.systemShare.d.ts）：
 *   1. SharedRecord.thumbnail 必须是 **Uint8Array 图片字节，且小于 32KB** ——
 *      超了会让整个 want 超过 IPC 阈值，分享面板直接起不来（1003702002）。
 *      所以封面要先下载 → 解码 → 缩到 180×240 → 压成 JPEG 60。
 *   2. utd 传 general.hyperlink、链接放 content，系统才会按「链接」处理，
 *      碰一碰分享和「复制链接」这些入口也才会出现。
 *   3. 自定义 scheme（libretv://）系统不认识其含义，但会原样带给对方，
 *      对方点开时由本 APP 的 skills 声明接住（见 module.json5）。
 *
 * 为什么要 prefetch：压缩略图要下载 + 解码，几百毫秒起步。等用户点分享才开始做，
 * 面板会明显迟滞（和「点了一键导入没反应」是同一类体验问题）。
 * 所以在详情页/播放页数据到手时就先算好，点分享时直接命中缓存。
 */

import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HttpClient, HttpResult } from '../net/HttpClient';
import { ShareLink, ShareTarget } from './ShareLink';

/** 单条记录缩略图上限 32KB，留 2KB 余量 */
const THUMB_MAX_BYTES: number = 30 * 1024;

/**
 * 直接写进分享文字的「打开方式」提示。
 *
 * 微信只放行白名单 scheme，且内置浏览器禁止网页跳 libretv:// —— 收到链接的人
 * 必须点右上角「···」→「在浏览器打开」才拉得起 APP。
 * 落地页也能提示，但那要部署域名；把这句话拼在片名后面，微信聊天里一眼就能看到，
 * 不依赖任何服务端，是成本最低、覆盖面最广的做法。
 */
const WECHAT_HINT: string = '打开后选择「在浏览器打开」播放';

export class ShareService {
  /**
   * 应用展示名（资源 brand_name）。
   *
   * 分享文案里的「来自 X」必须走这里，不要在页面里写死品牌字面量：
   * 品牌名由 scripts/brand.js 在构建时写进 brand_name（开源构建是 LibreTV，
   * 本机安装包可能是另一个名字），写死就会出现「应用名与分享卡片对不上」。
   */
  static brandName(ctx: common.UIAbilityContext): string {
    try {
      return ctx.resourceManager.getStringByNameSync('brand_name');
    } catch (e) {
      return '';
    }
  }

  private static cache: Map<string, Uint8Array> = new Map();
  private static inflight: Map<string, Promise<Uint8Array | undefined>> = new Map();

  /** 预生成缩略图：失败静默（分享时没有封面也能发，只是预览卡难看一点） */
  static prefetch(pic: string): void {
    if (pic === '' || ShareService.cache.has(pic) || ShareService.inflight.has(pic)) {
      return;
    }
    const job: Promise<Uint8Array | undefined> = ShareService.buildThumb(pic, 6000);
    ShareService.inflight.set(pic, job);
    job.then((b: Uint8Array | undefined) => {
      ShareService.inflight.delete(pic);
      if (b !== undefined) {
        ShareService.cache.set(pic, b);
      }
    }).catch(() => {
      ShareService.inflight.delete(pic);
    });
  }

  private static async thumb(pic: string, budgetMs: number): Promise<Uint8Array | undefined> {
    if (pic === '') {
      return undefined;
    }
    const hit: Uint8Array | undefined = ShareService.cache.get(pic);
    if (hit !== undefined) {
      return hit;
    }
    const job: Promise<Uint8Array | undefined> | undefined = ShareService.inflight.get(pic);
    if (job !== undefined) {
      // 已经在预取了，直接等它
      return await job;
    }
    // 没预取（例如列表里点进来的冷门入口）：现取现算，预算交给 HTTP 层。
    // 宁可分享面板少一张封面，也不要让用户等好几秒 —— 那又变成「点了没反应」。
    return await ShareService.buildThumb(pic, budgetMs);
  }

  private static async buildThumb(pic: string, timeoutMs: number): Promise<Uint8Array | undefined> {
    let src: image.ImageSource | undefined = undefined;
    let pm: image.PixelMap | undefined = undefined;
    const packer: image.ImagePacker = image.createImagePacker();
    try {
      const res: HttpResult = await HttpClient.getBytes(pic, {}, timeoutMs);
      if (!res.ok || res.bytes.length === 0) {
        return undefined;
      }
      // Uint8Array 可能只是大 buffer 上的视图，必须按 byteOffset 截出来
      const ab: ArrayBuffer =
        res.bytes.buffer.slice(res.bytes.byteOffset, res.bytes.byteOffset + res.bytes.byteLength) as ArrayBuffer;
      src = image.createImageSource(ab);
      const opt: image.DecodingOptions = { desiredSize: { width: 180, height: 240 } };
      pm = await src.createPixelMap(opt);
      let bytes: Uint8Array =
        new Uint8Array(await packer.packing(pm, { format: 'image/jpeg', quality: 60 }));
      if (bytes.length > THUMB_MAX_BYTES) {
        bytes = new Uint8Array(await packer.packing(pm, { format: 'image/jpeg', quality: 30 }));
      }
      return bytes.length > THUMB_MAX_BYTES ? undefined : bytes;
    } catch (e) {
      hilog.warn(0x0001, 'LibreTV', 'buildThumb failed');
      return undefined;
    } finally {
      if (pm !== undefined) {
        await pm.release();
      }
      if (src !== undefined) {
        await src.release();
      }
      await packer.release();
    }
  }

  /**
   * 拉起系统分享面板。返回 false 表示这台设备/这个系统版本不支持，
   * 调用方负责提示（不要静默失败，否则又变成「点了没反应」）。
   */
  static async shareMovie(ctx: common.UIAbilityContext, target: ShareTarget,
    description: string): Promise<boolean> {
    try {
      const link: string = ShareLink.build(target);
      const thumb: Uint8Array | undefined = await ShareService.thumb(target.pic, 1500);
      // 片名在前、提示在后：微信只展示一行标题，提示必须紧跟片名才不会被截掉
      // 兜底标题用应用自己的名字（资源 brand_name），别写死品牌字面量：
      // 换品牌 / 上架改名时这里会跟着变
      let appName: string = '';
      try {
        appName = ctx.resourceManager.getStringByNameSync('brand_name');
      } catch (e) {
        appName = '';
      }
      const head: string = target.title !== '' ? target.title : appName;
      const record: systemShare.SharedRecord = {
        utd: utd.UniformDataType.HYPERLINK,
        title: head + '｜' + WECHAT_HINT,
        description: description,
        content: link,
        label: 'HYPERLINK'
      };
      if (thumb !== undefined) {
        record.thumbnail = thumb;
      }
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      await controller.show(ctx, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DEFAULT
      });
      return true;
    } catch (e) {
      hilog.error(0x0001, 'LibreTV', 'shareMovie failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }
}
