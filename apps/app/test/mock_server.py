"""CourseSight 端到端测试用 mock 服务器:
- GET  /jwxt/timetable            → 伪造教务课表页(被 webview 抓取)
- POST /v1/chat/completions       → OpenAI 兼容端点:带 tools 时返回 submit_timetable
                                     工具调用;json_mode(审查)时返回"无问题"裁决
模拟器内通过 http://10.0.2.2:8765 访问。
"""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer

PAGE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>明湖大学教务系统 - 学生课表</title>
<style>.menu{color:#999} td{border:1px solid #ccc}</style>
<script>function nothing(){var x=1;}</script></head>
<body>
<div class="menu">首页 | 选课 | 成绩 | 通知</div>
<h2>明湖大学 本科生课表(2025-2026 第二学期)</h2>
<p>第1周周一为 2026-03-02,本学期共 18 周。</p>
<table>
<tr><td>节次</td><td>星期一</td><td>星期二</td><td>星期三</td><td>星期四</td><td>星期五</td></tr>
<tr><td>第1,2节</td><td>机器学习<br>周教授<br>理科楼A201<br>1-18周</td><td>&nbsp;</td>
<td>数据库系统<br>钱老师<br>理科楼B310<br>1-18周</td><td>&nbsp;</td><td>&nbsp;</td></tr>
<tr><td>第3,4节</td><td>&nbsp;</td><td>计算机网络<br>吴老师<br>实验楼502<br>1-9周(单)</td>
<td>&nbsp;</td><td>软件工程<br>郑老师<br>理科楼C110<br>1-18周</td><td>&nbsp;</td></tr>
<tr><td>第5,6节</td><td>数据挖掘<br>冯老师<br>理科楼A305<br>1-18周(双)</td><td>&nbsp;</td>
<td>&nbsp;</td><td>&nbsp;</td><td>操作系统<br>陈老师<br>理科楼B210<br>10-18周</td></tr>
</table>
<p>上课时间:第1节 08:00-08:45 第2节 08:55-09:40 第3节 10:00-10:45
第4节 10:55-11:40 第5节 14:00-14:45 第6节 14:55-15:40</p>
<div>教务处版权所有</div>
</body></html>"""

SUBMIT_TIMETABLE = {
    "totalWeeks": 18,
    "firstWeekMonday": "2026-03-02",
    "timeConfig": [
        {"section": 1, "startTime": "08:00", "endTime": "08:45"},
        {"section": 2, "startTime": "08:55", "endTime": "09:40"},
        {"section": 3, "startTime": "10:00", "endTime": "10:45"},
        {"section": 4, "startTime": "10:55", "endTime": "11:40"},
        {"section": 5, "startTime": "14:00", "endTime": "14:45"},
        {"section": 6, "startTime": "14:55", "endTime": "15:40"},
    ],
    "courses": [
        {"name": "机器学习", "teacher": "周教授", "location": "理科楼A201",
         "dayOfWeek": 1, "startSection": 1, "endSection": 2,
         "weeks": list(range(1, 19)), "confidence": 0.98},
        {"name": "数据库系统", "teacher": "钱老师", "location": "理科楼B310",
         "dayOfWeek": 3, "startSection": 1, "endSection": 2,
         "weeks": list(range(1, 19)), "confidence": 0.97},
        {"name": "计算机网络", "teacher": "吴老师", "location": "实验楼502",
         "dayOfWeek": 2, "startSection": 3, "endSection": 4,
         "weeks": [1, 3, 5, 7, 9], "confidence": 0.9},
        {"name": "软件工程", "teacher": "郑老师", "location": "理科楼C110",
         "dayOfWeek": 4, "startSection": 3, "endSection": 4,
         "weeks": list(range(1, 19)), "confidence": 0.95},
        {"name": "数据挖掘", "teacher": "冯老师", "location": "理科楼A305",
         "dayOfWeek": 1, "startSection": 5, "endSection": 6,
         "weeks": [2, 4, 6, 8, 10, 12, 14, 16, 18], "confidence": 0.88},
        {"name": "操作系统", "teacher": "陈老师", "location": "理科楼B210",
         "dayOfWeek": 5, "startSection": 5, "endSection": 6,
         "weeks": list(range(10, 19)), "confidence": 0.85},
    ],
}


def completions_response(payload):
    return json.dumps({
        "choices": [{"message": payload}],
        "usage": {"prompt_tokens": 1200, "completion_tokens": 400},
    })


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("[mock] " + fmt % args)

    def do_GET(self):
        if self.path.startswith("/jwxt/timetable"):
            body = PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path.startswith("/v1/chat/completions"):
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length).decode("utf-8")
            try:
                req = json.loads(raw)
            except Exception:
                req = {}
            uses_tools = "tools" in req
            if uses_tools:
                payload = {"tool_calls": [{
                    "function": {
                        "name": "submit_timetable",
                        "arguments": json.dumps(SUBMIT_TIMETABLE, ensure_ascii=False),
                    }
                }]}
            else:
                payload = {"content": json.dumps({"issues": [], "uncertain": []},
                                                ensure_ascii=False)}
            body = completions_response(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8765), Handler)
    print("mock server on :8765")
    server.serve_forever()
