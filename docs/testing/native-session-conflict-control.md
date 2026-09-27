# 原生会话过期与同段冲突：隔离控制方案

2026-09-26 22:45只读准备；22:50补入Mac旅程，2026-09-27 00:18补入iOS实际执行与独立核对。准备阶段不改变会话/正文，后续执行边界见各段记录；过期控制只修改主验收当时明确授权的单一合成会话。只读取现有代码、隔离应用的非凭据偏好、隔离SQLite与PG，不读取token_hash或Keychain凭据。适用账本F13/F27/L10，原生操作见[原生记录](native-ui-validation.md)，完成范围见[状态账本](development-status.md)。

## 固定边界与定位

只使用恢复服务 `http://127.0.0.1:53056`、PG 容器 `tl-restored-b399c867c3db`、库 `97c6c216-19ef-4e34-b97f-fecbf4653702`、epoch `08874133-4249-485c-8829-93d98cdb7485`。此为22:45历史服务定位：当时应用PID52493，maintenance=false。00:57已在同URL/库/epoch安全升级，旧PID不可再用于控制；新进程及只读对比见[恢复服务升级证明](restored-service-upgrade.md)。不需要暂停、重启、删容器、改凭据世代或读取 Keychain token。

只读定位结果：

| 项目 | 标识与状态 |
| --- | --- |
| 原生 deviceId | `16bea008-9dff-4d7d-abee-816704c17391`；与隔离 UserDefaults `connection.deviceId` 一致 |
| 原生 sessionId | `183b8b91-ac6b-44bd-97c5-6ad9c3e976be`，唯一未撤销的原生会话，credential_generation=1 |
| 现有阅读笔记 | `de82c808-8566-4b03-9d9b-e2351d0de31b`，移动后阅读笔记.md，revision=9、active、已同步 |
| 原生移动验收目录 | `836e9acd-a53f-466e-adc1-425e6f869416`，revision=4、active |
| 当前原生工作区 | 下述 SQLite；检查时无未完成队列 |

SQLite 路径（只能 `mode=ro`/`-readonly` 打开）：

```
/var/folders/jd/9gz27bzs5d55xdmkf57mljx00000gn/T/TokenLibrary-UI-verification-20260926/Libraries/68cc057895d3cd4705929985d80181026cb1778641ffdc666573ae186ae92595/library.sqlite
```

偏好为 `~/Library/Preferences/app.tokenlibrary.verification.TokenLibrary-UI-verification-20260926.plist`，只取 `connection.server/deviceId/libraryId/rootId`。不能仅按最近请求时间猜会话。若原生已重新登录，旧 sessionId 不应再用，先按设备与当前登录时刻重新定位。

现有 `/api/v1/test/` 路由只有 POST `backup/begin`、`backup/end`、`backup/run`、`purge` 和 GET `backups`。没有会话过期/冲突注入入口。这些路由仅在 TestHooks=true 时存在；当前任务不调用它们，也不借 purge 造故障。

服务端 `sessions` 字段为 id/device_id/library_id/token_hash/last_seen_at/revoked_at/credential_generation，**没有 created_at**。授权时以原子 UPDATE 检查 library、credential_generation、未撤销、闲置不足90天，然后更新 last_seen_at。到期返回401/UNAUTHORIZED，不续期；不能用 revoked_at 模拟“90天闲置过期”。`documents` 存 object_id/markdown_source/pdf_blob_id，metadata 在迁移后的 objects 上；冲突材料在 conflicts 与 revisions。原生正文表为 `working_documents`，不是 documents。

## A. 会话过期 → 保留本机 → 重新登录

1. 主验收先记录原生当前正文、待提交0和最近成功时间。保留当前库，不切换到独立“本机文档”工作区。
2. 可再次执行以下只读核对（不会返回 token_hash）：

```sh
docker exec tl-restored-b399c867c3db psql -X -U tl -d tl -v ON_ERROR_STOP=1 -c "BEGIN READ ONLY;
SELECT s.id,s.device_id,s.last_seen_at,s.revoked_at,d.name,d.platform
FROM sessions s JOIN devices d ON d.id=s.device_id
WHERE s.library_id='97c6c216-19ef-4e34-b97f-fecbf4653702'
AND s.device_id='16bea008-9dff-4d7d-abee-816704c17391'
ORDER BY s.last_seen_at DESC;
SELECT id,epoch,maintenance FROM libraries; COMMIT;"
```

3. **以下是待执行的唯一数据库变更**。双重限定会话/设备/库，校验 epoch、非维护、仍有效和恰好一行；不满足则事务整体回滚。只将指定会话闲置时间设为90天1秒前：

```sh
docker exec -i tl-restored-b399c867c3db psql -X -U tl -d tl -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
DO $$
DECLARE changed integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM libraries
    WHERE id='97c6c216-19ef-4e34-b97f-fecbf4653702'
      AND epoch='08874133-4249-485c-8829-93d98cdb7485'
      AND maintenance=false AND credential_generation=1
  ) THEN RAISE EXCEPTION 'Unexpected isolated library state'; END IF;
  UPDATE sessions SET last_seen_at=now()-interval '90 days 1 second'
  WHERE id='183b8b91-ac6b-44bd-97c5-6ad9c3e976be'
    AND device_id='16bea008-9dff-4d7d-abee-816704c17391'
    AND library_id='97c6c216-19ef-4e34-b97f-fecbf4653702'
    AND credential_generation=1 AND revoked_at IS NULL
    AND last_seen_at>=now()-interval '90 days';
  GET DIAGNOSTICS changed = ROW_COUNT;
  IF changed<>1 THEN RAISE EXCEPTION 'Expected exactly one live native session, got %',changed; END IF;
END $$;
SELECT id,last_seen_at,revoked_at FROM sessions
WHERE id='183b8b91-ac6b-44bd-97c5-6ad9c3e976be';
COMMIT;
SQL
```

4. 主验收等待下一次前台同步或点击重试，观察清晰的过期/重新登录提示；本机正文、原件与来源可读。继续在当前绑定库的笔记追加独特段落，如 `会话过期验收：本机修改保留。`，确认本机保存、待提交大于0且最近成功时间未更新。可退出重开验证草稿与队列持续存在，但无需关闭服务。
5. 原生使用同一53056地址及合成账号重新登录。观察回到原库、待提交归零、新增正文保留；只读核对该对象正文与新session。新 sessionId 必须不同；旧行仍应闲置过期，不能由手工 SQL“恢复活跃”来替代登录。
6. 记录 UI 提示、时间、旧/新 sessionId、对象 revision 与本机/云端正文。此旅程不等同另两端均已验收；会话撤销与到期的自动行为已有 [服务端测试](server-sync.md)。

## B. 同段冲突：原生本机编辑 + 正常 API 远端编辑

推荐独立新笔记，不改已有研究/来源资料。此流程不改库表正文或冲突表，不暂停服务，也不需要维护开关。

1. 原生新建并改名为 `原生同段冲突验收.md`，正文精确为下述文本；保存并等待待提交0：

```markdown
# 同段冲突验收

Conflict Anchor: base.

保留段落。
```

2. **只读准备请求文件**：从确切库中按完整名称取得恰好一个 active md，读取当前 revision 对应不可变快照，冻结基准与远端请求。命令仅查询 PG、写入合成 `/tmp` 文件，尚未登录或发操作：

```sh
python3 - <<'PY'
import json,os,pathlib,subprocess,uuid
container='tl-restored-b399c867c3db'
library='97c6c216-19ef-4e34-b97f-fecbf4653702'
epoch='08874133-4249-485c-8829-93d98cdb7485'
sql="""BEGIN READ ONLY;
SELECT coalesce(json_agg(json_build_object('objectId',o.id,'revision',o.revision,
 'snapshot',convert_from(r.snapshot_bytes,'UTF8')::json)), '[]')
FROM objects o JOIN libraries l ON l.id=o.library_id
JOIN revisions r ON r.library_id=l.id AND r.epoch=l.epoch
 AND r.object_id=o.id AND r.revision=o.revision
WHERE l.id='97c6c216-19ef-4e34-b97f-fecbf4653702'
 AND l.epoch='08874133-4249-485c-8829-93d98cdb7485' AND l.maintenance=false
 AND o.name='原生同段冲突验收.md' AND o.kind='md' AND o.state='active';
COMMIT;"""
rows=json.loads(subprocess.check_output(['docker','exec',container,'psql','-X','-U','tl','-d','tl','-Atq','-v','ON_ERROR_STOP=1','-c',sql],text=True))
assert len(rows)==1, 'Expected one exact active synthetic conflict note'
row=rows[0]; snap=row['snapshot']; source=snap['markdownSource']
assert source.count('Conflict Anchor: base.')==1
folder=pathlib.Path('/tmp/tokenlibrary-native-conflict-control')
folder.mkdir(mode=0o700,exist_ok=True)
path=folder/'prepared.json'
assert not path.exists(), 'Do not overwrite a frozen test operation'
device=str(uuid.uuid4()); operation=str(uuid.uuid4())
envelope={'protocolVersion':1,'operationId':operation,'epoch':epoch,'deviceId':device,
 'objectId':row['objectId'],'action':'updateDocument',
 'base':{'source':'revision','revision':row['revision']},
 'desiredSnapshot':{'name':snap['name'],'parentId':snap['parentId'],
 'markdownSource':source.replace('Conflict Anchor: base.','Conflict Anchor: remote.')}}
plan={'origin':'http://127.0.0.1:53056','libraryId':library,'baseSnapshot':snap,
 'baseRevision':row['revision'],'envelope':envelope}
fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f: json.dump(plan,f,ensure_ascii=False,indent=2)
print(json.dumps({'prepared':str(path),'objectId':row['objectId'],'baseRevision':row['revision'],'operationId':operation}))
PY
```

3. 原生退出登录但继续当前绑定资料库；不要选择另一个独立本机库。将同一段 `Conflict Anchor: base.` 改为 `Conflict Anchor: mac.`，其他内容不变，确认本机保存与待提交。此刻辅助端仍未写入。
4. **主验收明确进入远端提交步骤时**，执行以下正常 API 调用。它只创建一个专用辅助会话、读取目标、提交已冻结的单个 operation，最后 logout；不接触原生 token。请求 ID 保持不变，失败不能重新生成请求文件：

```sh
python3 - <<'PY'
import json,pathlib,urllib.error,urllib.request
folder=pathlib.Path('/tmp/tokenlibrary-native-conflict-control')
p=json.loads((folder/'prepared.json').read_text()); env=p['envelope']
origin=p['origin']; assert origin=='http://127.0.0.1:53056'
assert p['libraryId']=='97c6c216-19ef-4e34-b97f-fecbf4653702'
assert env['epoch']=='08874133-4249-485c-8829-93d98cdb7485'
assert env['desiredSnapshot']['name']=='原生同段冲突验收.md'
token=None

def call(path,body=None,operation=None):
    headers={'Content-Type':'application/json'}
    if token: headers.update({'Authorization':'Bearer '+token,'X-Library-Epoch':env['epoch']})
    if operation: headers['Idempotency-Key']=operation
    raw=None if body is None else json.dumps(body,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
    req=urllib.request.Request(origin+path,data=raw,headers=headers,method='GET' if body is None else 'POST')
    with urllib.request.urlopen(req,timeout=15) as response: return json.load(response)['data']

login=call('/api/v1/auth/login',{'username':'e2e','password':'e2e-password',
 'deviceId':env['deviceId'],'deviceName':'native-conflict-remote-control','platform':'test'})
token=login['sessionToken']
try:
    assert login['libraryId']==p['libraryId'] and login['epoch']==env['epoch']
    try:
        result=call('/api/v1/sync/operations/'+env['operationId'])
    except urllib.error.HTTPError as error:
        if error.code!=404: raise
        current=call('/api/v1/objects/'+env['objectId'])['snapshot']
        assert int(current['revision'])==p['baseRevision'], 'Object changed: inspect before submitting'
        assert current['name']==env['desiredSnapshot']['name']
        assert current['markdownSource']==p['baseSnapshot']['markdownSource']
        result=call('/api/v1/sync/operations',env,env['operationId'])
    assert result['status']=='committed', result
    (folder/'remote-result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(json.dumps({'status':result['status'],'revision':result['revision'],
      'objectId':env['objectId'],'operationId':env['operationId']}))
finally:
    ended=call('/api/v1/auth/logout',{})
    assert ended.get('loggedOut') is True
    print('Auxiliary session logged out; native session was not used.')
PY
```

5. 原生重新登录同一服务，观察“冲突与恢复草稿”。**当前 synchronize 先 pull 后 push**：未冻结的本机修改会生成 SQLite `sync_conflicts.kind=pull_merge`、`server_id=NULL`；这是正常的本机三方冲突，不能要求服务端 conflicts 表也有一条。界面应同时显示 base/mac/remote 对应内容，源码差异可展开，未处理前双方均保留。
6. 主验收在原生界面输入自定义合并文本 `Conflict Anchor: mac + remote.` 并保存。观察冲突消失、同步完成；只读核对 server documents 正文和本机 working_documents 一致，原保留段落仍在。本机冲突 state 应为 resolved，待提交归零。
7. 原生保留本机、采用服务器、过期冲突和第二原生客户端收敛是另外的验收分支，本次一个自定义合并旅程不代替全部分支。辅助API代表一个远端编辑者，不称为 iOS 原生端。

只读本机诊断 SQL（在上述 SQLite 使用 mode=ro）：

```sql
SELECT id,name,revision,status,markdown FROM working_documents
WHERE name='原生同段冲突验收.md';
SELECT operation_id,object_id,state,base_revision,request_json IS NOT NULL AS frozen
FROM pending_operations WHERE object_id='<prepared.json 的 objectId>';
SELECT id,object_id,kind,server_id,state,base_json,local_json,remote_json
FROM sync_conflicts WHERE object_id='<prepared.json 的 objectId>';
```

若另需**服务器创建冲突**的 UI 分支，先在维护窗口内让原生同段编辑发出请求，确认本机 `request_json IS NOT NULL` 与 base_revision 后退出登录；由主验收结束维护，再执行远端提交与原生重登。冻结请求保留旧基准，服务端返回 conflict 并提供 base/local/remote 材料。该分支涉及维护控制，需要另行协调；本文准备时未执行。不要直接 INSERT conflicts 或 UPDATE documents 来制造只存在于表中的假同步冲突。

## 已有自动测试与本次缺口

- `TestSessionIdleExpiryRenewalLogoutAndCredentialRevocation` 已验证 89天23小时续期、90天1秒过期、注销与凭据世代；原生到期后的路由/离线保留/重登仍需 A 的实际操作。
- `TestConflictMaterialsAndResolution` 通过真实 API 验证共同版本与两份改文、材料查询和解决；Core 也覆盖 pull_merge。B 负责证明真实编辑器/提示/比较/提交路径。
- 现有 tests/acceptance/main.go 会创建多类对象、执行备份与维护，不适合原样对当前 UI 会话运行。这里使用单对象、冻结请求和独立辅助会话，保留运行中服务与合成证据。


## A 的实际执行与只读核对（22:49—22:51）

主验收于2026-09-26 22:49执行上文A3，仅使指定原生会话闲置过期。真实Mac界面自动收到401并保留当前正文；最近成功时间保持22:48:54。主验收在同一笔记源码追加“会话过期验收：本机修改保留，重新登录后继续同步。”，界面确认本机已保存、待提交1；Quit、换入新构建并重开后，该段和队列仍在。22:50:31同址53056原生重新登录，界面待提交归零并显示已同步。上述界面步骤来自主验收实际操作，独立核对未操纵GUI。

22:50:53开始仅使用PG只读事务和SQLite mode=ro核对，结果如下：

| 核对项 | 结果 |
| --- | --- |
| 旧session | `183b8b91-ac6b-44bd-97c5-6ad9c3e976be`，last_seen_at=`2026-06-28T14:49:09.034093Z`，闲置超过90天、仍无效；revoked_at为空，证明此次测试是闲置到期而非主动撤销 |
| 新session | `260c1b59-cd0b-4dbb-b7c8-c1b7b529e497`，同deviceId，闲置有效、revoked_at为空；与旧会话不同 |
| 笔记 | `de82c808-8566-4b03-9d9b-e2351d0de31b`，云端与本机均revision10，active；本机状态“已同步”，新增完整中文段落均存在 |
| 正文一致性 | 本机与云端全文SHA-256均为 `2688ff35704d1dbf4692269dd49d94401b86b959bc233d1ec7c41ac2bc651c84` |
| 队列 | 全工作区pending/awaiting_remote/needs_edit/conflict为0；目标文档现有8条队列记录均为sent |
| 恢复库 | 库ID与epoch不变，maintenance=false；未修改或停止任何服务 |

结构化独立证据为 `/tmp/tokenlibrary-native-session-expiry-proof.json`；首次本机只读记录为 `/tmp/tokenlibrary-native-session-expiry-local-proof.json`。此项通过Mac“90天闲置过期→本机编辑→退出重开保留→重新登录→同步”这一旅程；iOS对应流程、主动撤销原生流程和B冲突旅程未由此关闭。A3中的旧session现在已经失效，再运行会被行数断言拒绝，不能据此重复注入。

## B 的实际执行与只读核对（22:53—23:00）

主验收在原生新建 `原生同段冲突验收.md`，对象ID `848d1b0d-98a8-44aa-b98a-2d1cd55cd7bd`，22:53:40基准正文保存并同步。随后按B步骤保留本机同段改为mac、通过专用辅助API会话提交remote。实际原生比较界面显示mac与remote两份正文，并展开共同版本base到两者的源码差异。主验收手动合并为以下全文，22:59:35冲突列表为空，关闭后原笔记仍选中、待提交0：

```markdown
# 同段冲突验收

Conflict Anchor: mac + remote.

保留段落。
```

23:00:16开始，独立使用PG只读事务与SQLite mode=ro核对；未修改任何资料或服务：

| 核对项 | 结果 |
| --- | --- |
| 云端/本机正文 | 均逐字符等于上述Markdown（保留末尾换行），revision均为5；本机状态“已同步”，云端active |
| 全文SHA-256 | 两侧均为 `b46365f4dabf1e7d26aacabab1bffe72903ba82f5de315ed1e235816a45e2eb6` |
| 本机冲突 | `016b8223-7605-402e-828d-d9c6134537c2`，kind=pull_merge、server_id=NULL、state=resolved |
| 三份材料 | 持久化base/local/remote分别保留 `Conflict Anchor: base.` / `mac.` / `remote.` |
| 同步队列 | 全工作区pending/awaiting_remote/needs_edit/conflict为0；本笔记4条sent，原离线修改1条superseded，最终解决操作基于revision4成功提交 |
| 服务端conflicts | 该对象0条，符合先pull时产生本机pull_merge的既定流程，不是材料丢失 |
| 服务状态 | 恢复库ID/epoch不变，maintenance=false，未操作服务进程或容器生命周期 |

结构化证据 `/tmp/tokenlibrary-native-conflict-resolution-proof.json` 保存本机/云端全文、hash、三份冲突材料和各操作状态。此项关闭一个真实Mac“离线同段编辑→远端API改文→比较源码差异→原生自定义合并→同步收敛”旅程；辅助API不是第二原生客户端。保留本机/采用服务器按钮分支、冻结请求的服务端冲突分支、解决期间远端再次变更和iOS原生冲突旅程仍需分别验收。

## iOS完整过期、离线便签和重登旅程（2026-09-27 00:13—00:18）

沿用同一53056隔离恢复服务、固定library/epoch与正在运行的PG，不重启服务、不改Mac会话。iOS设备为 `2c829440-24bb-4688-bea3-dbf5e24a6293`。只读定位到当前session `5c199f2d-b862-4e6a-810a-775b7b020980`；同设备的 `639ad13f-74cb-46ca-bc7c-3a9fe95d60d0` 最后触达23:30:34，与此前未签名包Keychain保存失败对应，未将其一并过期。

主验收确认当前笔记、待提交0和最近成功时间后授权执行。准备SQL限定当前session/device/library、正确epoch、credentialGeneration=1、maintenance=false、未撤销且最近10分钟活跃；要求该设备恰好一个最近10分钟活跃会话，UPDATE恰好一行，否则事务抛错回滚。00:13:15成功提交，仅将指定session的last_seen_at变成 `2026-06-28 16:13:14.059756+00`（执行时刻减90天1秒）；revoked_at仍NULL。没有用撤销冒充闲置过期，也没有改文档。

证据目录 `/tmp/tokenlibrary-ios-session-control-20260927`：`baseline.json`、`expire-exact-session.sql`、`expire-result.log`、`offline-pending.json`、`relogin-proof.json`。SQL是本次已执行的单会话控制记录，不是可重复通用脚本；现在旧会话已过期，不能重跑或替换ID去影响其他会话。

| 时点与动作 | 实际结果 |
| --- | --- |
| 00:13:01只读基线 | `iOS原生同步验收.md` / `5e33316b-2e32-4202-9c1a-4eb7a720b0f9` 三方revision60、全文hash `73e9d084aac189e15d964a9fffd398289d480b8083ff3ecf9e6ed2b7a5fd3393`；两端未完成队列0 |
| 00:13:27原生自动同步 | 显示服务器资料库离线、需要重新登录，原便签仍可读 |
| 00:14:28真实英文软键盘 | 新增第三个text块 `0206998c-f82e-4f82-9c01-6722e7bccdca`，内容精确为 `offline saved\n`；完成后待提交1，最近成功仍00:13:14 |
| 00:15:36只读离线核验 | 云端与Mac仍revision60/hash不变，Mac未完成队列0；iOS恰好1个pending updateDocument `b31e3f1a-4f9e-4e2c-a903-bec07907593e`，新块和尾换行已持久化 |
| 00:15—00:17系统退出/重开 | 主验收从AppSwitcher关闭验证应用并确认进程退出；00:15:50重开仍离线/待提交1/最近成功00:13:14。真实键盘搜索 `offline saved` 唯一命中；重开便签看到原图片、原文字与第三块 |
| 00:17:23原生重登 | 使用同一53056合成连接重新登录，自动同步归零，最近成功时间前进 |
| 00:18:25独立三方核验 | 服务器、Mac和iOS均revision61，全文/metadata/assets完全相同；两端全工作区未完成队列0 |

最终正文精确等于离线待提交快照，SHA-256为 `052f14f60b31a2313bb6f30ad690ba7c1f0b75c7361359ff5aa1ea69fa566abb`。以过期前完整序列化正文为前缀，恰好增加一个指定第三块；原image/text两块的ID、顺序、正文与caption逐字节不变，metadata/assets未变。模拟器、Mac和服务器原JPEG仍各99,573 B，SHA-256均 `9148530b0a85f35fad7b5b98ab5da2e6033c6f502c988aa1aa78b658f4ddbd17`。

新登录session为 `3eb700d3-9a0a-4f72-b096-e41cf68f4968`；旧 `5c199f2d…` 仍闲置过期、未被续期或人工恢复，revoked_at仍NULL。此旅程完成iOS指定会话到期、离线已下载资料阅读/搜索/编辑、真正退出重开和同库重登收敛。它不等于物理断网、全部附件逐一离线读取、后台调度或iOS同段冲突已验。


## 01:52 iOS原生同段冲突后续

此页22:59 Mac流程的远端编辑来自合成API，保留其原始边界。后续iOS和新Mac已分别在原生应用修改同一段，完成iOS正常重登形成pull_merge冲突、比较/稍后处理/退出重开，以及第二轮真实软键盘自定义合并和两端换文档重开；三方revision7/全文hash一致。第一轮AX setValue显示与实际请求不同，不计自定义合并通过，原证据保留。详见[iOS冲突与恢复证明](ios-conflict-recovery.md)，不能扩展为editor_drafts、保留本机/服务器按钮或冻结请求冲突分支。
