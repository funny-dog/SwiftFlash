#!/usr/bin/env bash
set -euo pipefail

# 生成 SwiftFlash 的自签名代码签名证书并导入钥匙串。每台发布机器只需运行一次。
#
# 为什么需要：ad-hoc 签名（codesign -s -）的签名规则是本次构建的 cdhash，每次升级都会变，
# macOS 会把新版本当成不同的程序，系统授权及后续应用内更新验签都无法保持连续。
# 使用固定证书签名后，签名规则为「bundle 标识 + 证书指纹」，跨版本保持一致。
#
# 私钥只保存在钥匙串里。请用「钥匙串访问」把该证书（含私钥）导出为 .p12 备份到安全位置。
#
# 环境变量：
#   SWIFTFLASH_SIGN_IDENTITY  证书名称，默认「SwiftFlash Self-Signed」（须与 build.sh 一致）
#   SWIFTFLASH_KEYCHAIN       导入的钥匙串路径，默认登录钥匙串

IDENTITY_NAME="${SWIFTFLASH_SIGN_IDENTITY:-SwiftFlash Self-Signed}"
KEYCHAIN="${SWIFTFLASH_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

# 不用 grep -q：它命中即退出，security 若仍在输出会收到 SIGPIPE，pipefail 下整条管道判为失败
if security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$IDENTITY_NAME\"" >/dev/null; then
  echo "钥匙串中已有签名证书「${IDENTITY_NAME}」，无需重复生成："
  security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$IDENTITY_NAME\""
  exit 0
fi

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

OPENSSL_BIN="/usr/bin/openssl"
if [ ! -x "$OPENSSL_BIN" ]; then
  OPENSSL_BIN="openssl"
fi

# 仅用于代码签名的证书：keyUsage=digitalSignature，extendedKeyUsage=codeSigning，有效期 10 年
"$OPENSSL_BIN" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$IDENTITY_NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

# .p12 只是导入钥匙串的中转格式：口令随机生成，脚本结束即随临时目录删除
P12_PASS="$("$OPENSSL_BIN" rand -hex 16)"
"$OPENSSL_BIN" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$IDENTITY_NAME" -out "$WORK/identity.p12" -passout "pass:$P12_PASS"

# -T /usr/bin/codesign：允许 codesign 使用该私钥。首次签名时系统仍可能询问一次，选「始终允许」
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null

echo "已生成并导入签名证书「${IDENTITY_NAME}」："
security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$IDENTITY_NAME\""
echo "（自签名证书显示 CSSMERR_TP_NOT_TRUSTED 属正常：签名规则只认证书指纹，不要求系统信任）"
echo
echo "证书 SHA-1 指纹：$("$OPENSSL_BIN" x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
echo "下一步：用「钥匙串访问」导出该证书（含私钥）备份；之后 bash scripts/build.sh 会自动用它签名。"
