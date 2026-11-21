# 미스터리 주식 시장

숨겨진 규칙으로 움직이는 7개 종목을 24라운드 동안 추리하며 거래하는 브라우저 멀티플레이 주식 게임입니다. 설치 없이 링크와 방 코드만으로 3~12명이 함께 플레이합니다.

- 플레이: https://mystery-stock-market.vercel.app
- 규칙: [RULES.md](RULES.md)

## 구조

```
web/        정적 프론트엔드 (빌드 없음) — index.html, app.js, style.css
supabase/   데이터베이스 스키마와 게임 로직 (Postgres 함수)
RULES.md    게임 규칙 명세
```

- **프론트엔드**: 순수 HTML/CSS/JS. Supabase REST(RPC)를 1.5초 간격으로 폴링합니다. Vercel에 정적 사이트로 배포합니다.
- **백엔드**: Supabase Postgres. 매매, 라운드 정산, 규칙 가림, 아이템 사용 등 모든 게임 로직은 `SECURITY DEFINER` 함수로만 실행되고, 테이블은 RLS로 직접 접근이 막혀 있습니다. 브라우저에 들어 있는 키는 공개용 anon 키이며 공개 RPC 9개만 호출할 수 있습니다.

## 데이터베이스 설정

새 Supabase 프로젝트에 아래 순서대로 SQL을 적용합니다.

1. `supabase/schema.sql` — 테이블, 기본 함수, 권한
2. `supabase/v2_mechanics.sql` — 랜덤 메커니즘 배정, 영향력 순 공개
3. `supabase/v3_state.sql` — 라운드별 기록, 시크릿 남은 라운드, 순위 변동
4. `supabase/v4_item_counts.sql` — 인원별 아이템 개수
5. `supabase/v5_new_mechanics.sql` — 메커니즘 15종 · 새 모양 · 방장 아이템 설정
6. `supabase/v6_lobby_chat.sql` — 대기방 채팅 (게임 시작 시 삭제)

그다음 `web/app.js` 상단의 `SB_URL`, `SB_KEY`를 해당 프로젝트의 URL과 anon(publishable) 키로 바꿉니다.

## 로컬 실행

`web/` 폴더를 아무 정적 서버로 띄우면 됩니다.

```bash
npx serve web
```
