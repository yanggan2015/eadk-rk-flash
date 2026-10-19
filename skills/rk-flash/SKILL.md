# EADK RK Flash — Agent Skill

调用本机或局域网 Agent 接口（不要使用 MCP）。路径前缀 **`/rk-flash`**，对外经 Gateway **TCP 18081**。

1. `GET http://{host}:18081/rk-flash/health`
2. `GET http://{host}:18081/rk-flash/api/help`
3. `GET http://{host}:18081/rk-flash/help`

直连本机：`http://127.0.0.1:18172/rk-flash/...`

PowerShell 用 `curl.exe`；JSON 用单引号，例如 `-d '{"action":"maskrom"}'`。

**一台设备可不带 `select`；多台必须 `select=LocationID`。**

## 示例

```bash
curl.exe -s http://127.0.0.1:18081/rk-flash/health
curl.exe -s http://127.0.0.1:18081/rk-flash/api/help
curl.exe -s http://127.0.0.1:18081/rk-flash/api/devices
curl.exe -s http://127.0.0.1:18081/rk-flash/api/relay-boards

curl.exe -s -X POST -H "Content-Type: application/json" -d '{"action":"maskrom"}' http://127.0.0.1:18081/rk-flash/api/action
curl.exe -s -X POST -H "Content-Type: application/json" -d '{"board":"BOARD"}' http://127.0.0.1:18081/rk-flash/api/enter-maskrom

curl.exe -s -X POST -H "Content-Type: application/json" -d '{"url":"http://172.16.45.24/dsp_release/noesis3588/QSemOS-24.03-LTS/boot.img"}' http://127.0.0.1:18081/rk-flash/api/flash
```
