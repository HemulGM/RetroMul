unit A5200.ASAP.Info;

interface

uses
  System.SysUtils, System.Math, A5200.Arithmetic, A5200.ASAP.Types,
  A5200.POKEY.Types;

procedure ASAPInfo_AddSong(ctx: TASAPInfo; playerCalls: Integer);

procedure ASAPInfo_Construct(ctx: TASAPInfo);

function ASAPInfo_GetChannels(ctx: TASAPInfo): Integer;

function ASAPInfo_GetCovoxAddress(ctx: TASAPInfo): Integer;

function ASAPInfo_GetInitAddress(ctx: TASAPInfo): Integer;

function ASAPInfo_GetMusicAddress(ctx: TASAPInfo): Integer;

function ASAPInfo_GetPlayerRateScanlines(ctx: TASAPInfo): Integer;

function ASAPInfo_GetRmtInstrumentFrames(module: TBytes; instrument: Integer; volume: Integer; volumeFrame: Integer; onExtraPokey: Boolean): Integer;

function ASAPInfo_GetSongs(ctx: TASAPInfo): Integer;

function ASAPInfo_GetWord(dataArray: TBytes; i: Integer): Integer;

function ASAPInfo_IsNtsc(ctx: TASAPInfo): Boolean;

function ASAPInfo_IsValidChar(c: Integer): Boolean;

function ASAPInfo_ParseModule(ctx: TASAPInfo; module: TBytes; moduleLen: Integer): Boolean;

function ASAPInfo_ParseRmt(ctx: TASAPInfo; module: TBytes; moduleLen: Integer): Boolean;

procedure ASAPInfo_ParseRmtSong(ctx: TASAPInfo; module: TBytes; globalSeen: TArray<Boolean>; songLen: Integer; posShift: Integer; pos: Integer);

function ASAPInfo_ValidateRmt(module: TBytes; moduleLen: Integer): Boolean;

implementation

procedure CheckRmtWorkLimit(var Steps: Integer); inline;
begin
  Inc(Steps);
  if Steps > 8000000 then
    raise EArgumentException.Create('RMT analysis exceeds work limit');
end;

function BytesText(const Data: TBytes; Count: Integer): AnsiString;
begin
  SetLength(Result, Count);
  for var I := 0 to Count - 1 do
    Result[I + 1] := AnsiChar(Data[I]);
end;

procedure ASAPInfo_AddSong(ctx: TASAPInfo; playerCalls: Integer);
var
  scanlines: Int64;
  songIndex1: Integer;
begin
  scanlines := S32(Int64(playerCalls) * ctx.fastplay);
  songIndex1 := ctx.songs;
  ctx.songs := S32(ctx.songs + 1);
  ctx.durations[songIndex1] := S32(((scanlines * 38000) div 591149));
end;

procedure ASAPInfo_Construct(ctx: TASAPInfo);
begin
  ctx.filename := '';
  ctx.author := '';
  ctx.title := '';
  ctx.date := '';
end;

function ASAPInfo_GetChannels(ctx: TASAPInfo): Integer;
begin
  Exit(S32(ctx.channels));
end;

function ASAPInfo_GetCovoxAddress(ctx: TASAPInfo): Integer;
begin
  Exit(S32(ctx.covoxAddr));
end;

function ASAPInfo_GetInitAddress(ctx: TASAPInfo): Integer;
begin
  Exit(S32(ctx.init));
end;

function ASAPInfo_GetMusicAddress(ctx: TASAPInfo): Integer;
begin
  Exit(S32(ctx.music));
end;

function ASAPInfo_GetPlayerRateScanlines(ctx: TASAPInfo): Integer;
begin
  Exit(S32(ctx.fastplay));
end;

function ASAPInfo_GetRmtInstrumentFrames(module: TBytes; instrument: Integer; volume: Integer; volumeFrame: Integer; onExtraPokey: Boolean): Integer;
var
  addrToOffset: Integer;
  perFrame: Integer;
  playerCall: Integer;
  playerCalls: Integer;
  index: Integer;
  indexEnd: Integer;
  indexLoop: Integer;
  volumeSlideDepth: Integer;
  volumeMin: Integer;
  RMT_VOLUME_SILENT: TArray<Byte>;
  vol: Integer;
  volumeSlide: Integer;
  silentLoop: Boolean;
begin
  var parseSteps := 0;
  addrToOffset := S32(Int64(ASAPInfo_GetWord(module, 2)) - 6);
  instrument := S32(Int64(S32(Int64(ASAPInfo_GetWord(module, 14)) - addrToOffset)) + S32((Int64(instrument) shl (1 and 31))));
  if (module[S32(Int64(instrument) + 1)] = 0) then
  begin
    Exit(S32(0));
  end;

  instrument := S32(Int64(ASAPInfo_GetWord(module, instrument)) - addrToOffset);
  perFrame := S32(module[12]);
  playerCall := S32(Int64(volumeFrame) * perFrame);
  playerCalls := S32(playerCall);
  index := S32(Int64(S32(Int64(module[instrument]) + 1)) + S32(Int64(playerCall) * 3));
  indexEnd := S32(Int64(module[S32(Int64(instrument) + 2)]) + 3);
  indexLoop := S32(module[S32(Int64(instrument) + 3)]);
  if (indexLoop >= indexEnd) then
  begin
    Exit(S32(0));
  end;

  volumeSlideDepth := S32(module[S32(Int64(instrument) + 6)]);
  volumeMin := S32(module[S32(Int64(instrument) + 7)]);
  SetLength(RMT_VOLUME_SILENT, 16);
  RMT_VOLUME_SILENT[0] := 16;
  RMT_VOLUME_SILENT[1] := 8;
  RMT_VOLUME_SILENT[2] := 4;
  RMT_VOLUME_SILENT[3] := 3;
  RMT_VOLUME_SILENT[4] := 2;
  RMT_VOLUME_SILENT[5] := 2;
  RMT_VOLUME_SILENT[6] := 2;
  RMT_VOLUME_SILENT[7] := 2;
  RMT_VOLUME_SILENT[8] := 1;
  RMT_VOLUME_SILENT[9] := 1;
  RMT_VOLUME_SILENT[10] := 1;
  RMT_VOLUME_SILENT[11] := 1;
  RMT_VOLUME_SILENT[12] := 1;
  RMT_VOLUME_SILENT[13] := 1;
  RMT_VOLUME_SILENT[14] := 1;
  RMT_VOLUME_SILENT[15] := 1;
  if (index >= indexEnd) then
  begin
    index := S32(Int64((S32(Int64(index) - indexEnd) mod S32(Int64(indexEnd) - indexLoop))) + indexLoop);
  end
  else
  begin
    while True do
    begin
      CheckRmtWorkLimit(parseSteps);
      vol := S32(module[S32(Int64(instrument) + index)]);
      if onExtraPokey then
      begin
        vol := S32(Sar32(vol, 4));
      end;
      if ((vol and 15) >= RMT_VOLUME_SILENT[volume]) then
      begin
        playerCalls := S32(Int64(playerCall) + 1);
      end;
      playerCall := S32(playerCall + 1);
      index := S32(Int64(index) + 3);
      if not ((index < indexEnd)) then
        Break;
    end;
  end;

  if (volumeSlideDepth = 0) then
  begin
    Exit(S32((playerCalls div perFrame)));
  end;

  volumeSlide := S32(128);
  silentLoop := False;
  while True do
  begin
    CheckRmtWorkLimit(parseSteps);
    if (index >= indexEnd) then
    begin
      if silentLoop then
        Break;

      silentLoop := True;
      index := S32(indexLoop);
    end;
    vol := S32(module[S32(Int64(instrument) + index)]);
    if onExtraPokey then
    begin
      vol := S32(Sar32(vol, 4));
    end;
    if ((vol and 15) >= RMT_VOLUME_SILENT[volume]) then
    begin
      playerCalls := S32(Int64(playerCall) + 1);
      silentLoop := False;
    end;
    playerCall := S32(playerCall + 1);
    index := S32(Int64(index) + 3);
    volumeSlide := S32(Int64(volumeSlide) - volumeSlideDepth);
    if (volumeSlide < 0) then
    begin
      volumeSlide := S32(Int64(volumeSlide) + 256);
      volume := S32(volume - 1);
      if (volume <= volumeMin) then
        Break;
    end;
  end;

  Exit(S32((playerCalls div perFrame)));
end;

function ASAPInfo_GetSongs(ctx: TASAPInfo): Integer;
begin
  Exit(S32(ctx.songs));
end;

function ASAPInfo_GetWord(dataArray: TBytes; i: Integer): Integer;
begin
  Exit(S32(Int64(dataArray[i]) + S32((Int64(dataArray[S32(Int64(i) + 1)]) shl (8 and 31)))));
end;

function ASAPInfo_IsNtsc(ctx: TASAPInfo): Boolean;
begin
  Exit(ctx.ntsc);
end;

function ASAPInfo_IsValidChar(c: Integer): Boolean;
begin
  Exit(((((c >= 32) and (c <= 124)) and (c <> 96)) and (c <> 123)));
end;

function ASAPInfo_ParseModule(ctx: TASAPInfo; module: TBytes; moduleLen: Integer): Boolean;
var
  musicLastByte: Integer;
  blockLen: Integer;
  infoAddr: Integer;
  infoLen: Integer;
begin
  if (((module[0] <> 255) or (module[1] <> 255)) and ((module[0] <> 0) or (module[1] <> 0))) then
    Exit(False);

  ctx.music := S32(ASAPInfo_GetWord(module, 2));
  musicLastByte := S32(ASAPInfo_GetWord(module, 4));
  if ((ctx.music <= 55295) and (musicLastByte >= 53248)) then
    Exit(False);

  blockLen := S32(Int64(S32(Int64(musicLastByte) + 1)) - ctx.music);
  if (S32(Int64(6) + blockLen) <> moduleLen) then
  begin
    if ((ctx.kind <> ASAPModuleType_RMT) or (S32(Int64(11) + blockLen) > moduleLen)) then
      Exit(False);

    infoAddr := S32(ASAPInfo_GetWord(module, S32(Int64(6) + blockLen)));
    if (infoAddr <> S32(Int64(ctx.music) + blockLen)) then
      Exit(False);

    infoLen := S32(Int64(S32(Int64(ASAPInfo_GetWord(module, S32(Int64(8) + blockLen))) + 1)) - infoAddr);
    if (S32(Int64(S32(Int64(10) + blockLen)) + infoLen) <> moduleLen) then
      Exit(False);
  end;

  Exit(True);
end;

function ASAPInfo_ParseRmt(ctx: TASAPInfo; module: TBytes; moduleLen: Integer): Boolean;
var
  posShift: Integer;
  perFrame: Integer;
  blockLen: Integer;
  songLen: Integer;
  globalSeen: TArray<Boolean>;
  pos: Integer;
  title: TArray<Byte>;
  titleLen: Integer;
  c: Integer;
  conditionValue5: Integer;
begin
  if not (ASAPInfo_ValidateRmt(module, moduleLen)) then
    Exit(False);

  case module[9] of
    52:
      begin
        posShift := S32(2);
      end;
    56:
      begin
        ctx.channels := S32(2);
        posShift := S32(3);
      end;
  else
    Exit(False);
  end;

  perFrame := S32(module[12]);
  if ((perFrame < 1) or (perFrame > 4)) then
    Exit(False);

  ctx.kind := S32(ASAPModuleType_RMT);
  if not (ASAPInfo_ParseModule(ctx, module, moduleLen)) then
    Exit(False);

  blockLen := S32(Int64(S32(Int64(ASAPInfo_GetWord(module, 4)) + 1)) - ctx.music);
  songLen := S32(Int64(S32(Int64(ASAPInfo_GetWord(module, 4)) + 1)) - ASAPInfo_GetWord(module, 20));
  if (((posShift = 3) and ((songLen and 4) <> 0)) and (module[S32(Int64(S32(Int64(6) + blockLen)) - 4)] = 254)) then
  begin
    songLen := S32(Int64(songLen) + 4);
  end;
  songLen := S32(Sar32(songLen, posShift));
  if (songLen >= 256) then
    Exit(False);

  SetLength(globalSeen, 256);
  globalSeen[0] := False;
  ctx.songs := S32(0);
  pos := S32(0);
  while ((pos < songLen) and (ctx.songs < 32)) do
  begin
    if not (globalSeen[pos]) then
    begin
      ctx.songPos[ctx.songs] := U8(pos);
      ASAPInfo_ParseRmtSong(ctx, module, globalSeen, songLen, posShift, pos);
    end;
    pos := S32(pos + 1);
  end;
  ctx.fastplay := S32((312 div perFrame));
  ctx.player := S32(1536);
  if (ctx.songs = 0) then
    Exit(False);

  SetLength(title, 127);
  titleLen := S32(0);
  while ((titleLen < 127) and (S32(Int64(S32(Int64(10) + blockLen)) + titleLen) < moduleLen)) do
  begin
    c := S32(module[S32(Int64(S32(Int64(10) + blockLen)) + titleLen)]);
    if (c = 0) then
      Break;

    if ASAPInfo_IsValidChar(c) then
    begin
      conditionValue5 := c;
    end
    else
    begin
      conditionValue5 := 32;
    end;
    title[titleLen] := U8(conditionValue5);
    titleLen := S32(titleLen + 1);
  end;
  ctx.title := BytesText(title, titleLen);

  Exit(True);
end;

procedure ASAPInfo_ParseRmtSong(ctx: TASAPInfo; module: TBytes; globalSeen: TArray<Boolean>; songLen: Integer; posShift: Integer; pos: Integer);
var
  addrToOffset: Integer;
  tempo: Integer;
  frames: Integer;
  songOffset: Integer;
  patternLoOffset: Integer;
  patternHiOffset: Integer;
  seen: TArray<Byte>;
  patternBegin: TArray<Integer>;
  patternOffset: TArray<Integer>;
  blankRows: TArray<Integer>;
  instrumentNo: TArray<Integer>;
  instrumentFrame: TArray<Integer>;
  volumeValue: TArray<Integer>;
  volumeFrame: TArray<Integer>;
  ch: Integer;
  p: Integer;
  i: Integer;
  patternRows: Integer;
  patternByteOffset9: Integer;
  patternByteOffset10: Integer;
  patternByteOffset11: Integer;
  patternByteOffset12: Integer;
  instrumentFrames: Integer;
  frame: Integer;
begin
  var parseSteps := 0;
  addrToOffset := S32(Int64(ASAPInfo_GetWord(module, 2)) - 6);
  tempo := S32(module[11]);
  frames := S32(0);
  songOffset := S32(Int64(ASAPInfo_GetWord(module, 20)) - addrToOffset);
  patternLoOffset := S32(Int64(ASAPInfo_GetWord(module, 16)) - addrToOffset);
  patternHiOffset := S32(Int64(ASAPInfo_GetWord(module, 18)) - addrToOffset);
  SetLength(seen, 256);
  for var z := 0 to High(seen) do
    seen[z] := 0;
  SetLength(patternBegin, 8);
  SetLength(patternOffset, 8);
  SetLength(blankRows, 8);
  SetLength(instrumentNo, 8);
  for var z := 0 to High(instrumentNo) do
    instrumentNo[z] := 0;
  SetLength(instrumentFrame, 8);
  for var z := 0 to High(instrumentFrame) do
    instrumentFrame[z] := 0;
  SetLength(volumeValue, 8);
  for var z := 0 to High(volumeValue) do
    volumeValue[z] := 0;
  SetLength(volumeFrame, 8);
  for var z := 0 to High(volumeFrame) do
    volumeFrame[z] := 0;
  while True do
  begin
    CheckRmtWorkLimit(parseSteps);
    if not ((pos < songLen)) then
      Break;

    if (seen[pos] <> 0) then
    begin
      if (seen[pos] <> 1) then
      begin
        ctx.loops[ctx.songs] := True;
      end;
      Break;
    end;
    seen[pos] := U8(1);
    globalSeen[pos] := True;
    if (module[S32(Int64(songOffset) + S32((Int64(pos) shl (posShift and 31))))] = 254) then
    begin
      pos := S32(module[S32(Int64(S32(Int64(songOffset) + S32((Int64(pos) shl (posShift and 31))))) + 1)]);
      Continue;
    end;

    ch := S32(0);
    while True do
    begin
      CheckRmtWorkLimit(parseSteps);
      if not ((ch < S32((Int64(1) shl (posShift and 31))))) then
        Break;

      p := S32(module[S32(Int64(S32(Int64(songOffset) + S32((Int64(pos) shl (posShift and 31))))) + ch)]);
      if (p = 255) then
      begin
        blankRows[ch] := S32(256);
      end
      else
      begin
        patternBegin[ch] := S32(Int64(S32(Int64(module[S32(Int64(patternLoOffset) + p)]) + S32((Int64(module[S32(Int64(patternHiOffset) + p)]) shl (8 and 31))))) - addrToOffset);
        patternOffset[ch] := S32(patternBegin[ch]);
        if (patternOffset[ch] < 0) then
          Exit;

        blankRows[ch] := S32(0);
      end;
      ch := S32(ch + 1);
    end;
    i := S32(0);
    while True do
    begin
      CheckRmtWorkLimit(parseSteps);
      if not ((i < songLen)) then
        Break;

      if (seen[i] = 1) then
      begin
        seen[i] := U8(2);
      end;
      i := S32(i + 1);
    end;
    patternRows := S32(module[10]);
    while True do
    begin
      CheckRmtWorkLimit(parseSteps);
      patternRows := S32(patternRows - 1);
      if not ((patternRows >= 0)) then
        Break;

      ch := S32(0);
      while True do
      begin
        CheckRmtWorkLimit(parseSteps);
        if not ((ch < S32((Int64(1) shl (posShift and 31))))) then
          Break;

        blankRows[ch] := S32(blankRows[ch] - 1);
        if (blankRows[ch] > 0) then
        begin
          Inc(ch);
          Continue;
        end;

        while True do
        begin
          CheckRmtWorkLimit(parseSteps);
          patternByteOffset9 := patternOffset[ch];
          patternOffset[ch] := S32(patternOffset[ch] + 1);
          i := S32(module[patternByteOffset9]);
          if ((i and 63) < 62) then
          begin
            patternByteOffset10 := patternOffset[ch];
            patternOffset[ch] := S32(patternOffset[ch] + 1);
            i := S32(Int64(i) + S32((Int64(module[patternByteOffset10]) shl (8 and 31))));
            if ((i and 63) <> 61) then
            begin
              instrumentNo[ch] := S32(Sar32(i, 10));
              instrumentFrame[ch] := S32(frames);
            end;
            volumeValue[ch] := S32((Sar32(i, 6) and 15));
            volumeFrame[ch] := S32(frames);
            Break;
          end;

          if (i = 62) then
          begin
            patternByteOffset11 := patternOffset[ch];
            patternOffset[ch] := S32(patternOffset[ch] + 1);
            blankRows[ch] := S32(module[patternByteOffset11]);
            Break;
          end;

          if ((i and 63) = 62) then
          begin
            blankRows[ch] := S32(Sar32(i, 6));
            Break;
          end;

          if ((i and 191) = 63) then
          begin
            patternByteOffset12 := patternOffset[ch];
            patternOffset[ch] := S32(patternOffset[ch] + 1);
            tempo := S32(module[patternByteOffset12]);
            Continue;
          end;

          if (i = 191) then
          begin
            patternOffset[ch] := S32(Int64(patternBegin[ch]) + module[patternOffset[ch]]);
            Continue;
          end;

          patternRows := S32((-1));
          Break;
        end;

        if (patternRows < 0) then
        begin
          Break;
        end;

        ch := S32(ch + 1);
      end;
      if (patternRows >= 0) then
      begin
        frames := S32(Int64(frames) + tempo);
      end;
    end;
    pos := S32(pos + 1);
  end;
  instrumentFrames := S32(0);
  ch := S32(0);
  while True do
  begin
    CheckRmtWorkLimit(parseSteps);
    if not ((ch < S32((Int64(1) shl (posShift and 31))))) then
      Break;

    frame := S32(instrumentFrame[ch]);
    frame := S32(Int64(frame) + ASAPInfo_GetRmtInstrumentFrames(module, instrumentNo[ch], volumeValue[ch], S32(Int64(volumeFrame[ch]) - frame), (ch >= 4)));
    if (instrumentFrames < frame) then
    begin
      instrumentFrames := S32(frame);
    end;
    ch := S32(ch + 1);
  end;
  if (frames > instrumentFrames) then
  begin
    if (S32(Int64(frames) - instrumentFrames) > 100) then
    begin
      ctx.loops[ctx.songs] := False;
    end;
    frames := S32(instrumentFrames);
  end;
  if (frames > 0) then
  begin
    ASAPInfo_AddSong(ctx, frames);
  end;
end;

function ASAPInfo_ValidateRmt(module: TBytes; moduleLen: Integer): Boolean;
begin
  if (moduleLen < 48) then
  begin
    Exit(False);
  end;

  if ((((module[6] <> 82) or (module[7] <> 77)) or (module[8] <> 84)) or (module[13] <> 1)) then
  begin
    Exit(False);
  end;

  Exit(True);
end;

end.

