/**
 * XMLTV 节目单解析（EPG）
 */

import { EpgProgramme } from './Types';

export interface XmltvParseResult {
  channels: Map<string, string>;
  programmes: EpgProgramme[];
}

export interface NowNextResult {
  current?: EpgProgramme;
  next?: EpgProgramme;
}

export class XmltvParser {
  static parse(xml: string): XmltvParseResult {
    const channels = new Map<string, string>();
    const programmes: EpgProgramme[] = [];
    if (xml === '') {
      return { channels: channels, programmes: programmes };
    }
    const channelRe = /<channel\s+id="([^"]*)"[^>]*>([\s\S]*?)<\/channel>/g;
    let m = channelRe.exec(xml);
    while (m !== null) {
      const id = m[1];
      const body = m[2];
      const dn = body.match(/<display-name[^>]*>([\s\S]*?)<\/display-name>/);
      channels.set(id, dn !== null ? XmltvParser.stripTags(dn[1]) : id);
      m = channelRe.exec(xml);
    }
    const progRe = /<programme\s+([^>]*)>([\s\S]*?)<\/programme>/g;
    m = progRe.exec(xml);
    while (m !== null) {
      const attrs = m[1];
      const channel = XmltvParser.attr(attrs, 'channel');
      const start = XmltvParser.parseTime(XmltvParser.attr(attrs, 'start'));
      const stop = XmltvParser.parseTime(XmltvParser.attr(attrs, 'stop'));
      const titleMatch = m[2].match(/<title[^>]*>([\s\S]*?)<\/title>/);
      const title = titleMatch !== null ? XmltvParser.stripTags(titleMatch[1]) : '';
      if (channel !== '' && start > 0) {
        programmes.push({
          channelId: channel,
          title: title,
          start: start,
          stop: stop > 0 ? stop : start + 1800000
        });
      }
      m = progRe.exec(xml);
    }
    return { channels: channels, programmes: programmes };
  }

  /** 匹配频道：优先 tvg-id，其次频道名相等 */
  static matchChannelId(channels: Map<string, string>, tvgId: string, name: string): string {
    if (tvgId !== '' && channels.has(tvgId)) {
      return tvgId;
    }
    if (tvgId !== '' && channels.size === 0) {
      return tvgId;
    }
    // 按显示名称匹配
    channels.forEach((value: string, key: string) => {
      if (value === name) {
        tvgId = key;
      }
    });
    return tvgId;
  }

  static nowNext(programmes: EpgProgramme[], id: string, now: number): NowNextResult {
    let current: EpgProgramme | null = null;
    let next: EpgProgramme | null = null;
    for (const p of programmes) {
      if (p.channelId !== id) {
        continue;
      }
      if (p.start <= now && p.stop > now) {
        current = p;
      } else if (p.start > now) {
        if (next === null || p.start < next.start) {
          next = p;
        }
      }
    }
    const out: NowNextResult = {};
    if (current !== null) {
      out.current = current;
    }
    if (next !== null) {
      out.next = next;
    }
    return out;
  }

  /** 20240101203000 +0800 → epoch ms */
  static parseTime(v: string): number {
    if (v === '') {
      return 0;
    }
    const m = v.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\s*([+-]\d{4})?/);
    if (m === null) {
      return 0;
    }
    const utc = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]));
    if (m[7] !== undefined) {
      const sign = m[7].startsWith('-') ? -1 : 1;
      const oh = Number(m[7].substring(1, 3));
      const om = Number(m[7].substring(3, 5));
      return utc - sign * (oh * 3600 + om * 60) * 1000;
    }
    return utc;
  }

  private static attr(attrs: string, key: string): string {
    const re = new RegExp(key + '="([^"]*)"');
    const m = attrs.match(re);
    return m !== null ? m[1] : '';
  }

  private static stripTags(s: string): string {
    return s.replace(/<[^>]*>/g, '').trim();
  }
}
