import { socket, http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { avSession } from '@kit.AVSessionKit';
import { HttpClient } from '../net/HttpClient';

export interface DlnaState {
  mediaUri: string;
  state: avSession.AVPlaybackState;
}

// Read-only UPnP fallback: some system controllers lose their media cache on app restart.
export class DlnaProbe {
  private static endpoints: Map<string, string> = new Map();

  static tag(xml: string, name: string): string {
    const match = xml.match(new RegExp('<(?:[\\w-]+:)?' + name + '(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[\\w-]+:)?' + name + '>'));
    return match === null ? '' : match[1].replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&').trim();
  }

  static time(value: string): number {
    if (!/^\d+:\d{2}:\d{2}(\.\d+)?$/.test(value)) { return 0; }
    const parts = value.split(':');
    return (Number(parts[0]) * 3600 + Number(parts[1]) * 60 + Number(parts[2])) * 1000;
  }

  private static async discover(name: string, serviceName: string = 'AVTransport'): Promise<string> {
    const udp = socket.constructUDPSocketInstance();
    const locations: string[] = [];
    try {
      await udp.bind({ address: '0.0.0.0', port: 0, family: 1 });
      udp.on('message', (message: socket.SocketMessageInfo) => {
        const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(message.message));
        const match = text.match(/(?:^|\r?\n)location:\s*(http:\/\/[^\s]+)/i);
        if (match !== null && locations.length < 12 && !locations.includes(match[1])) { locations.push(match[1]); }
      });
      await udp.send({ address: { address: '239.255.255.250', port: 1900, family: 1 },
        data: 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n' });
      await new Promise<void>((resolve) => { setTimeout(resolve, 1800); });
    } finally { await udp.close(); }
    for (const location of locations) {
      const response = await HttpClient.getText(location, {}, 1500);
      if (!response.ok || DlnaProbe.tag(response.text, 'friendlyName') !== name) { continue; }
      const services = response.text.match(/<service>[\s\S]*?<\/service>/g) ?? [];
      for (const service of services) {
        if (!DlnaProbe.tag(service, 'serviceType').includes(':' + serviceName + ':1')) { continue; }
        const control = DlnaProbe.tag(service, 'controlURL');
        const base = DlnaProbe.tag(response.text, 'URLBase') || location;
        const origin = base.match(/^http:\/\/[^/]+/);
        if (control.startsWith('http://')) { return control; }
        if (origin !== null && control !== '') {
          return control.startsWith('/') ? origin[0] + control : base.substring(0, base.lastIndexOf('/') + 1) + control;
        }
      }
    }
    throw new Error('未找到电视的标准投屏服务');
  }

  private static async soap(endpoint: string, action: string, argumentsXml: string = '', serviceName: string = 'AVTransport'): Promise<string> {
    const request = http.createHttp();
    try {
      const result = await request.request(endpoint, {
        method: http.RequestMethod.POST, connectTimeout: 1500, readTimeout: 1500,
        header: { 'Content-Type': 'text/xml; charset="utf-8"', 'SOAPAction': '"urn:schemas-upnp-org:service:' + serviceName + ':1#' + action + '"' },
        extraData: '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:' + action + ' xmlns:u="urn:schemas-upnp-org:service:' + serviceName + ':1"><InstanceID>0</InstanceID>' + argumentsXml + '</u:' + action + '></s:Body></s:Envelope>'
      });
      if (result.responseCode !== 200 || typeof result.result !== 'string') { throw new Error('电视状态查询失败'); }
      return result.result;
    } finally { request.destroy(); }
  }

  private static escape(value: string): string {
    return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  static async command(name: string, command: string, parameter: number = 0, mediaUri: string = ''): Promise<void> {
    let action = '';
    let body = '';
    const service = command === 'setVolume' ? 'RenderingControl' : 'AVTransport';
    if (command === 'play') { action = 'Play'; body = '<Speed>1</Speed>'; }
    else if (command === 'pause') { action = 'Pause'; }
    else if (command === 'stop') { action = 'Stop'; }
    else if (command === 'seek') {
      if (!Number.isFinite(parameter) || parameter < 0) { throw new Error('无效进度'); }
      const seconds = Math.floor(parameter / 1000);
      const time = Math.floor(seconds / 3600) + ':' + String(Math.floor(seconds / 60) % 60).padStart(2, '0') + ':' + String(seconds % 60).padStart(2, '0');
      action = 'Seek'; body = '<Unit>REL_TIME</Unit><Target>' + time + '</Target>';
    } else if (command === 'setVolume') {
      if (!Number.isFinite(parameter)) { throw new Error('无效音量'); }
      action = 'SetVolume'; body = '<Channel>Master</Channel><DesiredVolume>' + Math.round(Math.max(0, Math.min(100, parameter))) + '</DesiredVolume>';
    } else if (command === 'load' && /^https?:\/\//i.test(mediaUri)) {
      action = 'SetAVTransportURI'; body = '<CurrentURI>' + DlnaProbe.escape(mediaUri) + '</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>';
    } else { throw new Error('电视不支持此操作'); }
    const key = service === 'AVTransport' ? name : name + ':RenderingControl';
    let endpoint = DlnaProbe.endpoints.get(key);
    if (endpoint === undefined) { endpoint = await DlnaProbe.discover(name, service); DlnaProbe.endpoints.set(key, endpoint); }
    await DlnaProbe.soap(endpoint, action, body, service);
  }

  static async read(name: string): Promise<DlnaState> {
    let endpoint = DlnaProbe.endpoints.get(name);
    if (endpoint === undefined) { endpoint = await DlnaProbe.discover(name); DlnaProbe.endpoints.set(name, endpoint); }
    try {
      const position = await DlnaProbe.soap(endpoint, 'GetPositionInfo');
      const transport = await DlnaProbe.soap(endpoint, 'GetTransportInfo');
      const status = DlnaProbe.tag(transport, 'CurrentTransportState');
      if (!/^\d+:\d{2}:\d{2}(\.\d+)?$/.test(DlnaProbe.tag(position, 'RelTime'))) { throw new Error('电视未返回有效进度'); }
      if (status !== 'PLAYING' && status !== 'PAUSED_PLAYBACK' && status !== 'STOPPED') { throw new Error('电视尚未准备好'); }
      return { mediaUri: DlnaProbe.tag(position, 'TrackURI'), state: {
        state: status === 'PLAYING' ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : status === 'PAUSED_PLAYBACK' ? avSession.PlaybackState.PLAYBACK_STATE_PAUSE : avSession.PlaybackState.PLAYBACK_STATE_STOP,
        duration: DlnaProbe.time(DlnaProbe.tag(position, 'TrackDuration')),
        position: { elapsedTime: DlnaProbe.time(DlnaProbe.tag(position, 'RelTime')), updateTime: Date.now() }
      } };
    } catch (e) { DlnaProbe.endpoints.delete(name); throw new Error('标准投屏状态读取失败'); }
  }
}
