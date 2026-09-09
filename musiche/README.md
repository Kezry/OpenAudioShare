# musiche web 前端（已内联）

本目录原为指向 [HeHang0/musiche](https://github.com/HeHang0/musiche) 的 git 子模块，
现改为直接入库（固定自上游提交 `cef1e09`，"Fix update lyric on remote mode"），
以便对 Android 端内嵌播放器页面做安全修补。

Android 的 HTTP 服务（`HttpServer.java`）在 CI 中执行
`cd musiche/web && yarn install && yarn build-only`，
构建产物复制到 `android/app/src/main/assets` 随 APK 分发。

与上游相比的本地修改：

- `web/src/utils/utils.ts`：搜索关键词高亮生成时对曲名和关键词做 HTML 转义，
  防止云端 API 返回的内容通过 `v-html` 注入脚本（XSS）。
- `web/src/components/MusicList.vue`：非高亮场景改为文本插值渲染曲名，
  不再走 `v-html`。
- `web/src/components/Playlist.vue`：歌单名改为文本插值渲染。
- `web/src/views/playlist.vue`：歌单描述改为文本插值渲染。
- `web/package.json`：修正从上游带入的错误元数据（description/repository 指向 DevToys）。

上游更新如需同步，请基于上游新提交重新套用上述修改。
