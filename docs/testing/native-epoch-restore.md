# 同地址恢复的原生验收准备

截至2026-09-27 03:46，本轮已完成独立同URL真实恢复、旧会话401/本机保持/重登epoch提示，以及旧笔记“保留本机版本”以新操作收敛。**备份后新增且恢复库缺失的笔记仍出现HTTP404，未通过，原现场等待修复。** 下方先保留03:32准备记录，再追加实际阶段，不能把准备状态当作最终状态。前一轮两个Core客户端联合旅程见[自动恢复证明](epoch-restore-two-clients.md)。

## 03:32准备环境与边界

使用[有界编排](../../tests/acceptance/native_epoch_fixture.py)：新PG17容器、新源码二进制、新loopback端口；既有62036、51525、53056、56881、51350均未改变。编排只操作其持有的子进程和随机容器，备份/原件/证据输出在独立临时目录。SQL仅只读取证与创建空恢复数据库；正文、媒体和版本推进均通过正常HTTP API。

- 当前地址 `http://127.0.0.1:57143`，PG容器`tl-native-epoch-5bf8990a3e8c`，监督PID16406、App PID16426。租约截止 **04:31:42.972500+08:00**；结束只清理本轮进程/容器，保留备份和证据文件。
- 输出 `/private/var/folders/jd/9gz27bzs5d55xdmkf57mljx00000gn/T/tokenlibrary-native-epoch-9kw22u0f`，`state.json`记录实时阶段与deadline。不会记录会话token或密码。
- libraryId `6938cd0d-710c-40bc-8abe-b9c11b133b54`，原epoch `0077b0e2-0eb1-4de0-82e7-b69e90bdba33`，rootId `e1edf7d9-33a0-4055-bb45-0dbe3c76e6b9`。
- 首次准备使用56941，发现控制异常的失败兜底可改进后，在任何GUI登录前仅关闭那一轮自有环境并重建为上述57143。原轮输出保留，不能当作原生恢复证据。

## 03:32夹具与已执行准备步骤

| 资料 | ID | 备份 / 当前 |
| --- | --- | --- |
| Epoch 原有笔记.md | `f7e4ca4a-271c-46ab-80f7-cd8cf75efd56` | 备份rev1，当前rev2；原中文正文和PNG保留，后加`BackupLaterCloudRevision20260927` |
| Epoch 三页研究原件.pdf | `19726bda-289c-4f7f-93c6-6fbe871f2f3f` | 合法74791B三页PDF，备份和当前相同，无批注 |
| Epoch 备份后新增.md | `da49c159-8073-44bb-87e8-7375fea9524d` | 备份不存在，当前rev1，独特标记`EpochCreatedAfterBackup20260927` |

图片为合成`fixture-diagram.png`，50786B。两媒体采用新blob ID，输入SHA、正文全文、操作ID与回执在`state.json`和`seed-operations.json`。控制账号完成准备后正常logout，不替换原生账号会话。

真实`backup/run`生成`48a1c7d8-6c14-4d5e-8e41-700f6ebcb907`，`library-admin verify`成功；manifest SHA为`65953cf4c6a71db025a2c419bc949a2b1ed714503f6066f5e97564d89f5bf619`。`01-backup-baseline.json`与`02-native-login-baseline.json`记录前后对象和媒体。准备阶段未restore，不能把备份验证等同于本轮恢复成功。

## 按阶段执行的原生计划

1. 原生用新地址正常登录，等待两笔记/PDF下载完整，实际打开PNG和三页原件。保存本机只读基线，核正文/revision/blob SHA/可发送数0；不要注入本机SQLite。
2. 在Root明确发出下一阶段指令后，仅为此新服务开启短期维护（正常测试hook、带地址/library/epoch守卫和自动解除期限），保留原生旧会话。原生分别编辑两篇笔记，确认本机保存、待提交及最近成功未推进；抓取真实冻结请求与尾文。不能用退出登录代替旧session失效旅程。
3. Root发出阶段信号后，以下命令只发出一次受守卫的restore请求（本轮已于03:42执行，不可再次执行）。编排核对runId、URL、library、epoch、manifest SHA和`prepared`阶段后，停止自有App，把真实备份恢复到**同容器全新空数据库`restored`与空媒体目录**，随后用相同端口启动。

   ```sh
   python3 tests/acceptance/native_epoch_fixture.py restore \
     --state /private/var/folders/jd/9gz27bzs5d55xdmkf57mljx00000gn/T/tokenlibrary-native-epoch-9kw22u0f/state.json \
     --origin http://127.0.0.1:57143 \
     --library 6938cd0d-710c-40bc-8abe-b9c11b133b54 \
     --epoch 0077b0e2-0eb1-4de0-82e7-b69e90bdba33
   ```

4. 必须先核对新ready、同library/root、不同epoch、旧session/receipt已清空、原件SHA和源库保持，再让原生观察旧会话401及正文仍在；正常重登后观察epoch冲突。本机待处理数和可发送数分开记录，不能把阻塞冲突误称已同步完成。
5. 分别对旧笔记和备份后新增笔记执行明确的恢复选择，核对全文/ID或新副本ID、媒体、操作状态与云端收敛；原旧操作不得盲目重放。实际出现的UI和可用选择决定结论，不能预填两条都成功。

若恢复命令或启动失败，编排先用原数据库/原媒体目录重新启动原服务；失败及被拒绝的控制请求落盘并保留环境到租约截止，不立即清理源PG。不存在自动重试恢复或自动接受不同epoch的路径。当前只读审查/后续执行记录将追加在本文件；Root原生主记录仍独立维护。

## 控制器只读复核与准备验证

第二位代理只读检查了目标数据库allowlist、runId/origin/library/epoch/manifest/phase守卫，并指出请求文件直接写入的竞态。控制入口已改为先完整写临时文件/fsync，再用不覆盖的`os.link`原子发布；本地无服务自检通过错误origin/library/epoch拒绝、完整JSON及重复请求拒绝。当前活动监督进程不需要重启，后续控制命令使用修复后的独立入口。

实际源库快照在停止App之前读取。本轮计划先由维护hook等待在途写入排空，并保持维护期间不新登录或提交成功业务写，再触发restore；最后仍逐字段比对，不能宣称数据库物理冻结。新增`maintenance`控制入口核对本轮身份、PG library/epoch、实际监听PID及healthy非维护初态，默认240秒自动解除；检测到restore阶段/身份改变后停止控制，不误解除后继服务。此入口截至03:35仅完成语法和守卫审查，**还未执行维护**。

```sh
python3 tests/acceptance/native_epoch_fixture.py maintenance \
  --state /private/var/folders/jd/9gz27bzs5d55xdmkf57mljx00000gn/T/tokenlibrary-native-epoch-9kw22u0f/state.json \
  --origin http://127.0.0.1:57143 \
  --library 6938cd0d-710c-40bc-8abe-b9c11b133b54 \
  --epoch 0077b0e2-0eb1-4de0-82e7-b69e90bdba33 --ttl 240
```

维护控制以独立运行会话启动后尽早yield，输出deadline和提前结束marker；不能用阻塞等待妨碍Root及时操作。仅在Root发出下一阶段指令后启动。

## 03:40—03:46 实际恢复与已暴露的缺失对象失败

Root在新`connectionfinal`包正常GUI登录57143，实际看到PNG、三页PDF与两笔记，初始4对象含root、2媒体、sendable0。登录只读基线`/tmp/tokenlibrary-epoch-native-login-baseline.json`（Root）及`...-login-readonly.json`（独立查询）均保留。

03:40:56.680仅本轮57143进入维护，自动解除deadline03:44:56；正常hook与监听PID/library/epoch确认成功。Root在旧笔记追加`EpochNativeLocalOld20260927`，在备份后新增笔记追加`EpochNativeLocalNew20260927`。03:41:52独立`/tmp/tokenlibrary-epoch-native-before-restore-client.json`记录两篇完整正文、媒体、索引及两条pending：旧操作`3cee5d08-7560-48f9-ba13-086bcf2381a8`已冻结base2/oldEpoch，request SHA`bed346993b30c6238341225a24da81996b762201829bf4415ce215abbfabd965`；新操作`53fb108a-3497-416b-b2e5-d480adeebae8`尚未冻结。不能写成两条都已冻结。

Root明确授权后，执行前额外核维护true、无running job、实际监听仍PID16426，再发布一次完整受守卫请求。03:42:48.946恢复成功：同URL/library/root，epoch改为`bb6ca7dd-892b-406a-aee8-4d928316729c`，新App PID19664，ready=true/maintenance=false。`04-restored-before-login.json`逐值等备份对象和blob、sessions0/operations0；PDF74791B、PNG50786B的源/恢复文件hash均同。`05-original-source-retained.json`与停止前被观察state完全相等。维护watchdog发现restore开始后结束控制，未向后继发送end。

Root实际看到旧会话401、服务器资料库离线/待提交2，正文仍在。03:43:33客户端after401与before的8业务表、两操作完整字段、请求字节、两媒体和索引精确保持。03:43:55 `06-server-after-401.json`独立确认恢复库session0/operation0；原source保留旧native session ID`129b75b5-a1f3-4120-b480-d6912633d404`，未读取token或其hash列。

03:44正常GUI重登，生成不同session`658caea2-8e00-4ae3-841f-3ded554e6ec2`、同device`4d3843ff-68d3-43b2-b1fb-387f82e29c17`。本机正文未变，两旧操作转conflict且原immutable材料保持，sendable0；出现**3条open冲突**：旧笔记1条epoch_changed、新缺失笔记epoch_changed与deleted各1条。这里的待提交0不能记为恢复已完成。`07-after-login-before-resolution.json`证明恢复库仅root/PDF/旧笔记rev1，新对象不存在，operations仍空。

Root选择旧笔记“保留本机版本”后，新operation`cd6f0aa1-5d34-4479-afc8-118ad06c29ee`以新epoch/base1正常提交，旧笔记成为rev2。`08-after-keep-old-local{,-validation}.json`核对云端全文精确等before本机，包含CloudLater和Old标记各一次，正文SHA`83aa2879733d2500800af5ba8a36a156108a1402096a66ba18e69c4e66ef8c46`；旧3cee请求并未重放，客户端只正常转superseded。

**新缺失笔记尚未通过**：Root点击第一条同名冲突的“保留本机版本”得到HTTP404，表单未关闭，未盲试第二条。03:46:04 `09-after-missing-local-404.json`确认恢复库仍无新对象/新接受回执，只有旧笔记上述成功解决操作；两原旧operation仍无receipt、媒体与source保持。HTTP404是实际发送失败，不能由“无receipt”写成“没有发请求”。重复冲突及缺失对象恢复路径已交Core代理复现修复；原失败现场保持，后续应使用真实新包在原现场明确恢复，再判断闭环。

客户端阶段和独立validation由Catalog代理取证；服务端阶段由本代理只读查询，互不代替GUI操作。上述PDF未改原件，正常原生阅读位置可能产生本机记录，依实际阶段材料单列。此次仍不替代iOS完整epoch旅程、真实系统定时或公网部署。
