/**
 * Bangumi 每日放送（新番时间表）
 * 与 LibreTV bangumi.ts 使用同一公开接口（免 key）
 */

import { HttpClient } from '../net/HttpClient';
import { RecommendItem } from './Types';

export class BangumiClient {
  static async calendar(): Promise<RecommendItem[]> {
    const res = await HttpClient.getText('https://api.bgm.tv/calendar', {
      'User-Agent': 'LibreTV-OHOS (+https://github.com/LibreSpark/LibreTV)',
      'Accept': 'application/json'
    }, 8000);
    if (!res.ok) {
      return [];
    }
    try {
      const days = JSON.parse(res.text) as object;
      if (!Array.isArray(days)) {
        return [];
      }
      const items: RecommendItem[] = [];
      for (const entry of days as object[]) {
        const day = entry as Record<string, object>;
        const list = day['items'];
        if (!Array.isArray(list)) {
          continue;
        }
        for (const sub of list as object[]) {
          const s = sub as Record<string, object>;
          const nameCn = BangumiClient.str(s['name_cn']);
          const name = BangumiClient.str(s['name']);
          const title = nameCn !== '' ? nameCn : name;
          const images = s['images'] as Record<string, string> | null;
          let cover = '';
          if (images !== null && images !== undefined) {
            const large = images['large'];
            const common = images['common'];
            if (typeof large === 'string' && large !== '') {
              cover = large as string;
            } else if (typeof common === 'string' && common !== '') {
              cover = common as string;
            }
          }
          if (title === '' || cover === '') {
            continue;
          }
          let rating: string | undefined = undefined;
          const ratingObj = s['rating'] as Record<string, number> | null;
          if (ratingObj !== null && ratingObj !== undefined) {
            const score = ratingObj['score'];
            if (typeof score === 'number' && (score as number) > 0) {
              rating = (score as number).toFixed(1);
            }
          }
          items.push({
            id: '',
            title: title,
            cover: cover,
            rating: rating,
            isTv: true
          });
        }
      }
      return items;
    } catch (e) {
      return [];
    }
  }

  private static str(v: object): string {
    return typeof v === 'string' ? (v as string) : '';
  }
}
