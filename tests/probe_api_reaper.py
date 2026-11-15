"""Sonde des API Reaper utilisées par AutoEdit, dans une instance séparée (-newinst), projet vide temporaire.

Vérifie : référentiel de temps du take accessor (item à 10 s, décalage de départ 1 s), ordre des valeurs de
TimeMap_GetMeasureInfo (4/4 puis 6/8), extension d'un item coupé (révèle-t-elle la source suivante ?), copie d'un
item par chunk sans GUID, effet de la vitesse de lecture. Le journal est affiché à la fin (out/probe/probe.log).
"""
import os
import subprocess
import sys

import numpy as np
import soundfile as sf

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REAPER = r"C:\Program Files\REAPER (x64)\reaper.exe"
OUT = os.path.join(ROOT, "out", "probe")

LUA = r"""
local LOG = [[%(log)s]]
local WAV = [[%(wav)s]]
local function log(...) local f = io.open(LOG, "a") f:write(table.concat({...}, " "), "\n") f:close() end
local function quit() reaper.Main_SaveProject(0, false) reaper.Main_OnCommand(40004, 0) end

local function find_clicks(take, fs, t0, t1)
  -- renvoie les temps (référentiel de l'accessor) des échantillons > 0.5
  local acc = reaper.CreateTakeAudioAccessor(take)
  local a0, a1 = reaper.GetAudioAccessorStartTime(acc), reaper.GetAudioAccessorEndTime(acc)
  local n = math.floor((t1 - t0) * fs)
  local buf = reaper.new_array(n)
  reaper.GetAudioAccessorSamples(acc, fs, 1, t0, n, buf)
  local out, last = {}, -1
  for i = 1, n do
    if math.abs(buf[i]) > 0.5 and i - last > 100 then out[#out + 1] = string.format("%%.4f", t0 + (i - 1) / fs) last = i end
  end
  reaper.DestroyAudioAccessor(acc)
  return a0, a1, table.concat(out, " ")
end

local ok, err = xpcall(function()
  reaper.SetTempoTimeSigMarker(0, -1, 0, -1, -1, 120, 4, 4, false)
  reaper.SetTempoTimeSigMarker(0, -1, -1, 2, 0, 90, 6, 8, false)   -- mesure 3 (index 2) en 6/8 à 90
  reaper.UpdateTimeline()
  local function pk(...) local t = table.pack(...) local o = {} for i = 1, t.n do o[i] = tostring(t[i]) end return t.n .. " valeurs : " .. table.concat(o, " | ") end
  for m = 0, 4 do log("GetMeasureInfo", m, pk(reaper.TimeMap_GetMeasureInfo(0, m))) end
  log("GetMeasureInfo(1) via TimeMap_GetMeasureInfo existe ?", tostring(reaper.TimeMap_GetMeasureInfo ~= nil))
  log("QNToTime 8 =", reaper.TimeMap2_QNToTime(0, 8), " QNToTime 9.5 =", reaper.TimeMap2_QNToTime(0, 9.5))
  log("timeToBeats(7.0) =", pk(reaper.TimeMap2_timeToBeats(0, 7.0)))
  log("GetTimeSigAtTime(7.0) =", pk(reaper.TimeMap_GetTimeSigAtTime(0, 7.0)))

  reaper.InsertTrackAtIndex(0, false)
  local tr = reaper.GetTrack(0, 0)
  local it = reaper.AddMediaItemToTrack(tr)
  local take = reaper.AddTakeToMediaItem(it)
  local src = reaper.PCM_Source_CreateFromFile(WAV)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", 10)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 6)
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 1)
  reaper.UpdateArrange()
  log("source : clics à 1.5, 2.5, 3.5, 4.5, 5.5, 6.5 s du fichier ; item à 10 s, décalage 1 s, longueur 6 s")
  log("accessor (lecture 0..7) :", find_clicks(take, 22050, 0, 7))
  log("accessor (lecture 10..17) :", find_clicks(take, 22050, 10, 17))

  -- coupe à 12.0 (projet) puis extension de la partie gauche de 0.8 s
  local right = reaper.SplitMediaItem(it, 12.0)
  log("après coupe : gauche pos/len", reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH"),
      " droite pos/len/offs", reaper.GetMediaItemInfo_Value(right, "D_POSITION"), reaper.GetMediaItemInfo_Value(right, "D_LENGTH"),
      reaper.GetMediaItemTakeInfo_Value(reaper.GetActiveTake(right), "D_STARTOFFS"))
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 2.8)
  log("gauche étendue à 2.8 s, accessor 0..3 :", find_clicks(reaper.GetActiveTake(it), 22050, 0, 3))
  reaper.SetMediaItemInfo_Value(right, "D_POSITION", 12.01)
  log("droite déplacée à 12.01, accessor 0..4 :", find_clicks(reaper.GetActiveTake(right), 22050, 0, 4))
  -- extension vers la gauche de la partie droite : position - 0.6 et décalage - 0.6
  local tk = reaper.GetActiveTake(right)
  reaper.SetMediaItemInfo_Value(right, "D_POSITION", 11.41)
  reaper.SetMediaItemInfo_Value(right, "D_LENGTH", reaper.GetMediaItemInfo_Value(right, "D_LENGTH") + 0.6)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS") - 0.6)
  log("droite étendue à gauche de 0.6, accessor 0..2 :", find_clicks(tk, 22050, 0, 2))

  -- chunk sans GUID
  local _, ch = reaper.GetItemStateChunk(right, "", false)
  local n = 0
  for line in ch:gmatch("[^\n]+") do if line:match("^%%s*I?GUID") or line:match("GUID") then n = n + 1 log("ligne GUID :", line) end end
  local ch2 = ch:gsub("\n%%s*IGUID [^\n]*", ""):gsub("\n%%s*GUID [^\n]*", "")
  reaper.InsertTrackAtIndex(1, false)
  local tr2 = reaper.GetTrack(0, 1)
  local it2 = reaper.AddMediaItemToTrack(tr2)
  reaper.SetItemStateChunk(it2, ch2, false)
  local g1 = reaper.BR_GetMediaItemGUID and reaper.BR_GetMediaItemGUID(right) or select(2, reaper.GetSetMediaItemInfo_String(right, "GUID", "", false))
  local g2 = select(2, reaper.GetSetMediaItemInfo_String(it2, "GUID", "", false))
  local tg1 = select(2, reaper.GetSetMediaItemTakeInfo_String(reaper.GetActiveTake(right), "GUID", "", false))
  local tg2 = select(2, reaper.GetSetMediaItemTakeInfo_String(reaper.GetActiveTake(it2), "GUID", "", false))
  log("copie : GUID item", g1, "->", g2, " GUID take", tg1, "->", tg2, " pos", reaper.GetMediaItemInfo_Value(it2, "D_POSITION"))
  log("items piste 2 :", reaper.CountTrackMediaItems(tr2))

  -- vitesse de lecture
  reaper.SetMediaItemTakeInfo_Value(tk, "D_PLAYRATE", 2.0)
  log("droite à vitesse 2, accessor 0..2 :", find_clicks(tk, 22050, 0, 2), " marqueurs d'étirement :", reaper.GetTakeNumStretchMarkers(tk))
end, debug.traceback)
if not ok then log("ERREUR LUA :", tostring(err)) end
log("FIN")
quit()
"""


def main():
    os.makedirs(OUT, exist_ok=True)
    fs = 44100
    x = np.zeros(int(8 * fs), np.float32)
    for t in (1.5, 2.5, 3.5, 4.5, 5.5, 6.5):
        x[int(t * fs)] = 0.9
        x[int(t * fs) + 1] = 0.9
    wav = os.path.join(OUT, "clicks.wav")
    sf.write(wav, x, fs, subtype="FLOAT")
    log = os.path.join(OUT, "probe.log")
    if os.path.exists(log):
        os.remove(log)
    proj = os.path.join(OUT, "probe.rpp")
    with open(proj, "w", encoding="utf-8") as fh:
        fh.write('<REAPER_PROJECT 0.1 "7.0/win64" 0 0\n  SAMPLERATE 44100 0 0\n  TEMPO 120 4 4\n>\n')
    script = os.path.join(OUT, "probe.lua")
    with open(script, "w", encoding="utf-8") as fh:
        fh.write(LUA % {"log": log, "wav": wav})
    subprocess.run([REAPER, "-newinst", "-nosplash", proj, script], timeout=120)
    with open(log, encoding="utf-8", errors="replace") as fh:
        sys.stdout.write(fh.read())


if __name__ == "__main__":
    main()
