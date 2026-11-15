// 自签名 TLS 证书（ECDSA P-256 + SHA-256，X.509 v3），只用 Node 自带的 crypto 生成：不依赖系统的 openssl。
// DER 按 RFC 5280 手工编码：TBSCertificate、签名算法、签名值；扩展有 subjectAltName（主机名和 IP）、basicConstraints、
// keyUsage、extendedKeyUsage(serverAuth)。
import { X509Certificate, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { isIP } from 'node:net';

const len = n => {
  if (n < 0x80) return Buffer.from([n]);
  const bytes = [];
  for (let v = n; v > 0; v >>= 8) bytes.unshift(v & 0xff);
  return Buffer.from([0x80 | bytes.length, ...bytes]);
};
const tlv = (tag, ...parts) => { const body = Buffer.concat(parts); return Buffer.concat([Buffer.from([tag]), len(body.length), body]); };
const seq = (...p) => tlv(0x30, ...p);
const set = (...p) => tlv(0x31, ...p);
const explicit = (n, ...p) => tlv(0xa0 + n, ...p);
const octets = buf => tlv(0x04, buf);
const bitString = buf => tlv(0x03, Buffer.from([0]), buf);
const bool = v => tlv(0x01, Buffer.from([v ? 0xff : 0]));
const utf8 = s => tlv(0x0c, Buffer.from(s, 'utf8'));
const integer = buf => { let b = Buffer.from(buf); while (b.length > 1 && b[0] === 0 && !(b[1] & 0x80)) b = b.subarray(1); if (b[0] & 0x80) b = Buffer.concat([Buffer.from([0]), b]); return tlv(0x02, b); };
const oid = dotted => {
  const [a, b, ...rest] = dotted.split('.').map(Number);
  const out = [40 * a + b];
  for (const n of rest) {
    const chunk = [n & 0x7f];
    for (let v = n >> 7; v > 0; v >>= 7) chunk.unshift(0x80 | (v & 0x7f));
    out.push(...chunk);
  }
  return tlv(0x06, Buffer.from(out));
};
const time = d => {   // UTCTime up to 2049, GeneralizedTime after (RFC 5280 4.1.2.5)
  const p = n => String(n).padStart(2, '0');
  const y = d.getUTCFullYear(), rest = `${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}Z`;
  return y < 2050 ? tlv(0x17, Buffer.from(`${String(y).slice(2)}${rest}`)) : tlv(0x18, Buffer.from(`${y}${rest}`));
};
const ipBytes = ip => isIP(ip) === 4 ? Buffer.from(ip.split('.').map(Number))
  : (() => { const [h, t = ''] = ip.split('::'); const hs = h ? h.split(':') : [], ts = t ? t.split(':') : [];
             const all = [...hs, ...Array(8 - hs.length - ts.length).fill('0'), ...ts];
             return Buffer.concat(all.map(x => { const b = Buffer.alloc(2); b.writeUInt16BE(parseInt(x || '0', 16)); return b; })); })();

/** A self-signed certificate for `hosts` (names) and `ips`, valid for `days`. Returns { key, cert } as PEM strings. */
export function selfSigned({ commonName = 'Strata', hosts = [], ips = [], days = 3650 } = {}) {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const ecdsaSha256 = seq(oid('1.2.840.10045.4.3.2'));
  const name = seq(set(seq(oid('2.5.4.3'), utf8(commonName))));
  const now = new Date(Date.now() - 60_000), until = new Date(now.getTime() + days * 86_400_000);
  const san = seq(...[...new Set(hosts)].filter(Boolean).map(h => tlv(0x82, Buffer.from(h))),
                  ...[...new Set(ips)].filter(ip => isIP(ip)).map(ip => tlv(0x87, ipBytes(ip))));
  const extensions = explicit(3, seq(
    seq(oid('2.5.29.17'), octets(san)),                                           // subjectAltName
    seq(oid('2.5.29.19'), bool(true), octets(seq())),                             // basicConstraints: not a CA
    seq(oid('2.5.29.15'), bool(true), octets(tlv(0x03, Buffer.from([7, 0x80])))), // keyUsage: digitalSignature
    seq(oid('2.5.29.37'), octets(seq(oid('1.3.6.1.5.5.7.3.1')))),                 // extendedKeyUsage: serverAuth
  ));
  const serial = randomBytes(16); serial[0] &= 0x7f;
  const tbs = seq(explicit(0, integer(Buffer.from([2]))), integer(serial), ecdsaSha256, name, seq(time(now), time(until)), name,
                  publicKey.export({ type: 'spki', format: 'der' }), extensions);
  const signature = sign('sha256', tbs, privateKey);   // ECDSA, DER (r, s)
  const der = seq(tbs, ecdsaSha256, bitString(signature));
  const cert = `-----BEGIN CERTIFICATE-----\n${der.toString('base64').match(/.{1,64}/g).join('\n')}\n-----END CERTIFICATE-----\n`;
  new X509Certificate(cert);   // throws when the encoding is wrong: never hand out a broken certificate
  return { key: privateKey.export({ type: 'pkcs8', format: 'pem' }), cert };
}
