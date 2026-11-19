# dist

发布用的成品包，`all` 架构，由编译机产出后放到这里。

[Release 工作流](../.github/workflows/release.yml) 会把这些文件原样附到 GitHub Release 上，
并生成 `sha256sums.txt`。所以**换版本时直接覆盖这里的文件**，不要手改文件名里的版本号
之外的任何东西。

| 文件 | 来源 |
|---|---|
| `luci-app-prio-<ver>.apk` | `make package/luci-app-prio/compile` |
| `luci-i18n-prio-zh-cn-<ver>.apk` | 同一个 luci feed 编出来的翻译包 |

校验和不要手写，由工作流在发布时生成。
