# 安全说明 / Security Policy

## 支持范围

安全修复优先面向最新正式版。请先确认问题是否仍存在于 [最新 Release](https://github.com/funny-dog/SwiftFlash/releases/latest)。历史版本不承诺提供补丁。

## 私密报告

请通过 GitHub 的 [Report a vulnerability](https://github.com/funny-dog/SwiftFlash/security/advisories/new) 私密提交安全问题，避免在公开 Issue 中披露尚未修复的漏洞细节。

请提供受影响版本、macOS 版本、复现步骤、预期与实际结果、安全影响，以及必要的最小示例。文件操作或插件验证问题请使用临时测试目录复现。不要提交真实私人文件、签名私钥、令牌或其他凭据。

适合私密报告的问题包括插件包路径穿越或校验绕过、工作区越界文件读写、命令注入等。普通功能故障或界面问题请使用 GitHub Issues 反馈。

## English

Security fixes prioritize the latest stable release; patches for older versions are not guaranteed. Please check the [latest release](https://github.com/funny-dog/SwiftFlash/releases/latest) before reporting.

Use [Report a vulnerability](https://github.com/funny-dog/SwiftFlash/security/advisories/new) to report vulnerabilities privately. Include the affected app and macOS versions, reproduction steps, expected and actual results, security impact, and a minimal example. Use disposable test folders when reproducing file or plugin issues. Do not include private files, signing keys, tokens, or other credentials.

Examples include plugin archive path traversal or checksum bypass, writes outside the intended workspace, and command injection. Use public issues for ordinary functional or UI bugs. Avoid publishing details of unpatched vulnerabilities in public issues.
