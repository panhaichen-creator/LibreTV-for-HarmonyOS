/**
 * 一键导入的推荐点播源（Apple CMS V10）。
 *
 * 来源：2026-10-19 对主流聚合仓（单仓聚合 / 老刘备 / 饭太硬 / 小马）里
 * 全部 type 0/1 CMS 站点做批量验活（ac=list 有内容、ac=detail 回显 vod_id）后筛出，
 * 当时通过 8 个。源会失效，导入后建议在源列表里先做一次测速再启用。
 *
 * 注意：这里只放 Apple CMS 源。TVBox 的 type:3（csp_* / spider JAR）不能放进来 ——
 * HarmonyOS 没有 JVM，加载不了 dex，加了也只会是死源。
 */
import { ExportVodEntry } from './Types';

export const RECOMMENDED_VOD: ExportVodEntry[] = [
  { name: '建设资源', api: 'http://154.219.117.232:9981/jacloudapi.php/provide/vod', isAdult: false },
  { name: '索尼资源', api: 'https://suoniapi.com/api.php/provide/vod', isAdult: false },
  { name: '量子资源', api: 'http://cj.lziapi.com/api.php/provide/vod', isAdult: false },
  { name: '非凡资源', api: 'http://ffzy.tv/api.php/provide/vod', isAdult: false },
  { name: '电影天堂', api: 'http://caiji.dyttzyapi.com/api.php/provide/vod', isAdult: false },
  { name: '红牛资源', api: 'https://www.hongniuzy2.com/api.php/provide/vod', isAdult: false },
  { name: '光速资源', api: 'https://api.guangsuapi.com/api.php/provide/vod', isAdult: false },
  { name: '极速资源', api: 'https://jszyapi.com/api.php/provide/vod', isAdult: false }
];
