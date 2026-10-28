# 自签泛域名证书
此工具用于颁发泛域名证书，方便开发环境调试。

请勿用于生产环境，生产环境还是购买正式的证书。  
或者到 [Let's Encrypt](https://letsencrypt.org/) 可以申请到免费证书  
（支持多域名和泛域名）。

## 优点
1. 你可以创建任意网站证书，只需导入一次根证书，无需多次导入；
1. 减少重复又无谓的组织信息输入，创建证书时只需要输入域名；
1. 泛域名证书可以减少 `nginx` 配置，例如你要模拟 CDN：  
假设你的项目网站是 `example.dev`，CDN 网站设置为 `cdn.example.dev`，  
你只需在 `nginx` 里面配置一个网站，`server_name` 同时填写  `example.dev`  
和 `cdn.example.dev`，它们可以使用同一个 `*.example.dev` 的证书。
1. 现在你只需要一个证书，就可以搞定所有项目网站！

使用 `SAN` 来支持多域名和泛域名：
```ini
subjectAltName=DNS:*.one.dev,DNS:one.dev,DNS:*.two.dev,DNS:two.dev,DNS:*.three.dev,DNS:three.dev
```

## 系统要求
1. Linux / macOS，bash，openssl（1.1.1 及以上）
1. 可选：`keytool`（JDK 自带），用于额外生成 Tomcat 的 JKS 证书
1. 事先用 `hosts` 或者 `dnsmasq` 解析你本地开发的域名，  
例如把 `example.dev` 指向 `127.0.0.1`

## 使用
```bash
./ssl.sh
```
按提示操作：

1. **选择根证书**：列出 `root/` 下的所有根证书，或选择 `0` 新建根证书。  
   自带默认根证书 `root/default-2099-12-31`（缺失时会自动生成）。  
   新建根证书需填写组织信息和时长，保存到 `root/<组织>-<到期日>/`。
1. **签发网站证书**：输入域名或 IP（多个用空格或逗号分隔，支持 `*.example.dev`），  
   以及证书时长和 Tomcat 证书密码。保存到 `cert/<域名>-<到期日>/`。

时长支持 `2y`（年）、`24m`（月）、`825d`（天）或直接输入到期日 `2099-12-31`。

> 注意：macOS/iOS 不信任有效期超过 825 天的网站证书。

## 输出
```text
root/<组织>-<到期日>/
    root.crt                 根证书，导入操作系统并信任
    root.key.pem             根证书私钥，妥善保管
cert/<域名>-<到期日>/
    <域名>.crt               网站证书
    <域名>.key.pem           网站证书私钥
    <域名>.txt               网站证书的组织、域名、到期时间等信息
    <域名>.bundle.crt        拼接好根证书的证书链，用于 nginx
    <域名>.p12               Tomcat 证书（PKCS12，alias 为 tomcat）
    <域名>.jks               Tomcat 证书（JKS，需要 keytool）
    root.crt                 签发此证书的根证书
    root.txt                 根证书的组织、到期时间等信息
    tomcat.txt               Tomcat server.xml 配置示例
```

把根证书导入到操作系统里面，信任这个证书，之后由它签发的网站证书都会被信任。

## 清空
删除 `cert/` 下对应的目录即可删除网站证书；删除 `root/` 下的目录即可删除根证书。

## 参考 / 致谢
[Vault and self signed SSL certificates](http://dunne.io/vault-and-self-signed-ssl-certificates)

[利用OpenSSL创建自签名的SSL证书备忘](http://wangye.org/blog/archives/732/)

[Provide subjectAltName to openssl directly on command line](http://security.stackexchange.com/questions/74345/provide-subjectaltname-to-openssl-directly-on-command-line)

## 关于 Let's Encrypt 客户端
官方客户端 `certbot` [太复杂了](https://github.com/Neilpang/acme.sh/issues/386)，推荐使用 [acme.sh](https://github.com/Neilpang/acme.sh/wiki/%E8%AF%B4%E6%98%8E)。

## 关于 .dev 域名
[Chrome to force .dev domains to HTTPS via preloaded HSTS](https://ma.ttias.be/chrome-force-dev-domains-https-via-preloaded-hsts/) ([2017-9-16](https://chromium-review.googlesource.com/c/chromium/src/+/669923))

## 关于 Chrome 信任证书问题
看到有人反映 Chrome 下无法信任证书，可参考 [这个文档](docs/chrome-trust.md)
