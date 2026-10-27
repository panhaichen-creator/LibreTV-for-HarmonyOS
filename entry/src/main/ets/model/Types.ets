/**
 * 全局类型定义（与 LibreTV Web 版数据结构对齐）
 */

export interface VodSource {
  key: string;
  name: string;
  /** Apple CMS V10 接口地址，如 https://example.com/api.php/provide/vod */
  url: string;
  detail?: string;
  enabled: boolean;
  isAdult: boolean;
  /** 健康度：连续失败次数 */
  failStreak: number;
  /** 停用截止时间戳（0 表示未停用） */
  disabledUntil: number;
}

export interface LiveSource {
  key: string;
  name: string;
  /** M3U/M3U8 播放列表地址 */
  url: string;
  /** XMLTV 节目单地址（可选） */
  epg?: string;
  enabled: boolean;
  failStreak: number;
  disabledUntil: number;
}

export interface SearchItem {
  sourceKey: string;
  sourceName: string;
  vodId: string;
  name: string;
  pic?: string;
  typeName?: string;
  year?: string;
  area?: string;
  remarks?: string;
  actor?: string;
  director?: string;
  content?: string;
  playFrom?: string;
  playUrl?: string;
}

/** 跨源同名聚合后的卡片 */
export interface MergedVideo {
  name: string;
  year?: string;
  pic?: string;
  typeName?: string;
  remarks?: string;
  area?: string;
  items: SearchItem[];
}

export interface Episode {
  index: number;
  name: string;
  url: string;
}

/** 播放线路：一部影片可有多个播放来源（vod_play_from / vod_play_url 按 $$$ 对齐） */
export interface PlayLine {
  name: string;
  episodes: Episode[];
}

export interface DetailInfo {
  title: string;
  cover?: string;
  desc?: string;
  typeName?: string;
  year?: string;
  area?: string;
  director?: string;
  actor?: string;
  remarks?: string;
  /** 源站评分（CMS 的 vod_score），可能是 '0.0' / ''，由详情页判断是否可用 */
  score?: string;
  sourceKey: string;
  sourceName: string;
  sourceUrl: string;
  /** 多条播放线路；只有 1 条时不返回 */
  lines?: PlayLine[];
}

export interface VideoDetail {
  episodes: Episode[];
  info: DetailInfo;
}

export interface PlayRecord {
  sourceKey: string;
  vodId: string;
  name: string;
  pic?: string;
  sourceName: string;
  /** 当前集下标 */
  episode: number;
  episodeName?: string;
  /** 播放地址（换源后可能变化） */
  playUrl?: string;
  /** 播放线路下标（多线路影片记忆所选线路） */
  lineIndex?: number;
  positionMs: number;
  durationMs: number;
  updatedAt: number;
}

export interface FavoriteItem {
  sourceKey: string;
  vodId: string;
  name: string;
  pic?: string;
  sourceName: string;
  createdAt: number;
}

/** 直播频道收藏项：与点播 FavoriteItem 并列存储，一起进「我的收藏」 */
export interface LiveFavoriteItem {
  url: string;
  name: string;
  logo?: string;
  sourceKey: string;
  sourceName: string;
  createdAt: number;
}

export interface LiveChannel {
  id: string;
  name: string;
  url: string;
  logo?: string;
  group?: string;
  tvgId?: string;
}

export interface LiveChannelItem extends LiveChannel {
  sourceKey: string;
  sourceName: string;
}

export interface EpgProgramme {
  channelId: string;
  title: string;
  start: number;
  stop: number;
}

export interface DownloadTaskRecord {
  id: string;
  sourceKey: string;
  vodId: string;
  name: string;
  pic?: string;
  sourceName: string;
  episode: number;
  episodeName: string;
  /** pending / downloading / completed / failed */
  status: string;
  done: number;
  total: number;
  dir: string;
  updatedAt: number;
  error?: string;
  /** 原始分集播放地址；存下来才能在应用被系统回收后继续下载 */
  episodeUrl?: string;
}

/**
 * 订阅导出结构。
 * 键名必须与 SubscriptionParser.parseSourceList 读取的一致（sources / liveSources），
 * 否则导出的文件粘回「导入订阅」会被解析成空列表。
 */
export interface ExportVodEntry {
  name: string;
  api: string;
  isAdult?: boolean;
}

export interface ExportLiveEntry {
  name: string;
  url: string;
  epg?: string;
}

export interface SourceExportPayload {
  name: string;
  updateTime: string;
  sources: ExportVodEntry[];
  liveSources: ExportLiveEntry[];
}

export interface SpeedTestItem {
  sourceKey: string;
  sourceName: string;
  /** 换源后该源中同名视频的 id（用于重新拉取详情） */
  vodId?: string;
  episodeUrl: string;
  latencyMs: number;
  ok: boolean;
  episodeCount: number;
}

export interface RecommendItem {
  id: string;
  title: string;
  cover: string;
  rating?: string;
  isTv: boolean;
}

export interface Settings {
  /** off / loose / strict */
  adFilter: string;
  autoNext: boolean;
  adultFilter: boolean;
  /** system / light / dark */
  themeMode: string;
  /** douban_movie / douban_tv / douban_rank / bangumi */
  recommendSource: string;
  defaultSpeed: number;
  playHistoryEnabled: boolean;
  /** 自动发现源：启动时拉取内置聚合订阅并验活入库（默认关闭） */
  autoDiscover: boolean;
}

export const DEFAULT_SETTINGS: Settings = {
  adFilter: 'loose',
  autoNext: true,
  adultFilter: true,
  themeMode: 'system',
  recommendSource: 'douban_movie',
  defaultSpeed: 1.0,
  playHistoryEnabled: true,
  autoDiscover: false
};
