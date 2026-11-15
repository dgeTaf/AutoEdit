"""Test de bout en bout dans un VRAI Reaper (instance séparée -newinst, projet temporaire dans out/e2e).

Projet : 200 BPM 4/4, piste « guitar_left » (DI réelle de l'utilisateur) et « bass Sat » (DI réelle), items à 0 s.
Le script Lua généré : charge AutoEdit.lua avec le crochet AUTOEDIT_TEST, sélectionne pistes et plage,
  1. analyse (export par take accessor + moteur Python) -> résumé ;
  2. applique (copie du .rpp, pistes « AutoEdit original », coupes) -> nombre d'items ;
  3. réanalyse : les attaques calées doivent être sur la ligne (|écart| < 0,5 ms) ;
  4. retour à l'état d'avant -> items d'origine (positions, longueurs) ;
puis enregistre et quitte. --capture : capture de la fenêtre AutoEdit seule après l'analyse. Journal : out/e2e/e2e.log (affiché à la fin). Toute erreur Lua est journalisée.
"""
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REAPER = r"C:\Program Files\REAPER (x64)\reaper.exe"
OUT = os.path.join(ROOT, "out", "e2e")
GUITAR = r"F:\reaper\death\15-guitar_left-260814_1725.wav"
BASS = r"F:\reaper\death\23-bass Sat-260814_1739.wav"
CAPTURE = "--capture" in sys.argv     # capture de la seule fenêtre AutoEdit après l'analyse (out/capture_gui.png)

LUA = r"""
local LOG = [[%(log)s]]
local CAPTURE = %(capture)s
local function log(...) local t = {} for i, v in ipairs({...}) do t[i] = tostring(v) end
  local f = io.open(LOG, "a") f:write(table.concat(t, " "), "\n") f:close() end
local function quit() if AUTOEDIT_TEST then AUTOEDIT_TEST.stop = true end reaper.Main_SaveProject(0, false) reaper.Main_OnCommand(40004, 0) end
local orig_defer = reaper.defer
reaper.defer = function(fn)
  orig_defer(function()
    local ok, e = xpcall(fn, debug.traceback)
    if not ok then log("ERREUR LUA : " .. tostring(e)) quit() end
  end)
end
-- boîtes de dialogue : jamais bloquantes en test (réponse « Oui »)
reaper.ShowMessageBox = function(msg, title, typ) log("BOITE : " .. msg:gsub("\n", " / ")) return 6 end

local function add_track(idx, name, file)
  reaper.InsertTrackAtIndex(idx, false)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  local it = reaper.AddMediaItemToTrack(tr)
  local tk = reaper.AddTakeToMediaItem(it)
  local src = reaper.PCM_Source_CreateFromFile(file)
  reaper.SetMediaItemTake_Source(tk, src)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", 0)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", reaper.GetMediaSourceLength(src))
  return tr
end
local function items_desc(tr)
  local t = {}
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, i)
    t[#t + 1] = string.format("%%.4f+%%.4f", reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))
  end
  return #t .. " items [" .. table.concat(t, " ", 1, math.min(#t, 4)) .. (#t > 4 and " ..." or "") .. "]"
end

reaper.SetTempoTimeSigMarker(0, -1, 0, -1, -1, 200, 4, 4, false)
reaper.UpdateTimeline()
local g = add_track(0, "guitar_left", [[%(guitar)s]])
local b = add_track(1, "bass Sat", [[%(bass)s]])
reaper.SetOnlyTrackSelected(g)
reaper.SetTrackSelected(b, true)
reaper.GetSet_LoopTimeRange(true, false, 1.2, 7.2, false)
reaper.Main_SaveProject(0, false)
local before_g, before_b = items_desc(g), items_desc(b)
log("avant : guitare " .. before_g .. " ; basse " .. before_b)

local stage, n, t0 = "start", 0, reaper.time_precise()
local function summary(A, title)
  for _, tt in ipairs(A.tracks) do
    local c = tt.count or {}
    log(string.format("%%s %%s : %%d attaques dans la plage, %%d sûres, %%d à caler, %%d hors grille, %%d douteuses, %%d bloquées",
      title, tt.t.name, c.n or -1, c.sure or -1, c.move or -1, c.offgrid or -1, c.doubtful or -1, tt.n_blocked or 0))
    local offs, big = {}, 0
    for _, o in ipairs(tt.onsets) do
      if o.status ~= "outside" and o.status ~= "join" and o.sure and o.off_ms and o.status ~= "offgrid" then
        offs[#offs + 1] = math.abs(o.off_ms)
        if math.abs(o.off_ms) > 0.5 then big = big + 1 end
      end
    end
    table.sort(offs)
    local med = offs[math.max(1, math.floor(#offs / 2))] or -1
    local p95 = offs[math.max(1, math.floor(#offs * 0.95))] or -1
    log(string.format("   écarts |sûres sur la grille| : n=%%d médiane %%.2f ms, p95 %%.2f ms, > 0,5 ms : %%d", #offs, med, p95, big))
    local lv = {}
    for i, l in ipairs(tt.levels or {}) do lv[#lv + 1] = (l.key or "-") .. (l.irregular and "!" or "") end
    log("   subdivisions par mesure : " .. table.concat(lv, " "))
  end
end

AUTOEDIT_TEST = { on_frame = function(api)
  n = n + 1
  local A, job, session, status = api.state()
  local now = reaper.time_precise() - t0
  if stage == "done" then return end
  if now > 150 then log("ÉCHEC : délai dépassé à l'étape " .. stage .. " ; statut : " .. status) AUTOEDIT_TEST.stop = true quit() return end
  if stage == "start" and n == 3 then
    api.start() stage = "analyse" log("analyse lancée ; statut : " .. status)
  elseif stage == "analyse" and not job and n > 4 then
    if not A then log("ÉCHEC analyse : " .. status) quit() return end
    log(string.format("analyse en %%.1f s ; statut : %%s", now, status))
    api.recompute()
    summary(A, "AVANT")
    if CAPTURE then
      local f = io.open(LOG .. ".capture", "w") f:write("go") f:close()
      stage, n = "wait_capture", 0
    else
      stage = "apply"
    end
  elseif stage == "wait_capture" then
    if reaper.file_exists(LOG .. ".captured") or n > 400 then stage = "apply" end
  elseif stage == "apply" then
    reaper.Main_SaveProject(0, false)
    api.apply()
    log("application ; statut : " .. select(4, api.state()))
    log("après : guitare " .. items_desc(g) .. " ; basse " .. items_desc(b) .. " ; pistes : " .. reaper.CountTracks(0))
    for i = 0, reaper.CountTracks(0) - 1 do log("   piste " .. i .. " : " .. select(2, reaper.GetTrackName(reaper.GetTrack(0, i)))) end
    reaper.SetOnlyTrackSelected(g)
    reaper.SetTrackSelected(b, true)
    stage, n = "reanalyse0", 0
  elseif stage == "reanalyse0" and n == 2 then
    api.start() stage = "reanalyse"
  elseif stage == "reanalyse" and not job and n > 3 then
    if not A then log("ÉCHEC réanalyse : " .. status) quit() return end
    api.recompute()
    summary(A, "APRÈS")
    stage = "revert"
  elseif stage == "revert" then
    api.revert()
    log("retour : " .. select(4, api.state()))
    local ag, ab = items_desc(g), items_desc(b)
    log("après retour : guitare " .. ag .. " ; basse " .. ab)
    log((ag == before_g and ab == before_b) and "RETOUR OK : items identiques" or "RETOUR DIFFÉRENT")
    log("FIN")
    AUTOEDIT_TEST.stop = true
    quit()
    stage = "done"
  end
end }
dofile([[%(script)s]])
"""


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    log = os.path.join(OUT, "e2e.log")
    proj = os.path.join(OUT, "e2e.rpp")
    with open(proj, "w", encoding="utf-8") as fh:
        fh.write('<REAPER_PROJECT 0.1 "7.0/win64" 0 0\n  SAMPLERATE 44100 0 0\n  TEMPO 200 4 4\n>\n')
    script = os.path.join(OUT, "e2e.lua")
    with open(script, "w", encoding="utf-8") as fh:
        fh.write(LUA % {"log": log, "guitar": GUITAR, "bass": BASS, "script": os.path.join(ROOT, "AutoEdit.lua"),
                         "capture": "true" if CAPTURE else "false"})
    proc = subprocess.Popen([REAPER, "-newinst", "-nosplash", proj, script])
    t0 = time.time()
    while proc.poll() is None and time.time() - t0 < 240:
        if CAPTURE and os.path.exists(log + ".capture") and not os.path.exists(log + ".captured"):
            time.sleep(2.0)      # quelques images dessinées
            shot = os.path.join(ROOT, "out", "capture_gui.png")
            r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                                os.path.join(ROOT, "tests", "capture_window.ps1"), "-ProcId", str(proc.pid),
                                "-Title", "AutoEdit", "-Out", shot], capture_output=True, text=True)
            print("capture :", shot, r.stdout.strip(), r.stderr.strip()[:300])
            open(log + ".captured", "w").close()
        time.sleep(0.3)
    if proc.poll() is None:
        proc.kill()
        print("Reaper ne s'est pas fermé (délai) ; journal partiel :")
    with open(log, encoding="utf-8", errors="replace") as fh:
        sys.stdout.write(fh.read())
    with open(log, encoding="utf-8", errors="replace") as fh:
        txt = fh.read()
    sys.exit(0 if ("RETOUR OK" in txt and "ERREUR" not in txt and "ÉCHEC" not in txt) else 1)


if __name__ == "__main__":
    main()
