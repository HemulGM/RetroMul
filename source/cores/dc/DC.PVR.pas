unit DC.PVR;

// PowerVR2 (CLX2) register file, sync pulse generator and framebuffer
// scanout. Rendering and the tile accelerator live in separate units and
// are attached through TDCPVR.TA / OnStartRender.
// References: Marcus Comstedt's Dreamcast pages, KallistiOS pvr_regs.h.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, DC.Types, DC.Memory, DC.Scheduler, DC.Interrupts;

const
  PVRID = $000;
  PVRRevision = $004;
  PVRSoftReset = $008;
  PVRStartRender = $014;
  PVRParamBase = $020;
  PVRRegionBase = $02C;
  PVRBorderColor = $040;
  PVRFBRCtrl = $044;
  PVRFBWCtrl = $048;
  PVRFBWLineStride = $04C;
  PVRFBRSOF1 = $050;
  PVRFBRSOF2 = $054;
  PVRFBRSize = $05C;
  PVRFBWSOF1 = $060;
  PVRFBWSOF2 = $064;
  PVRFBXClip = $068;
  PVRFBYClip = $06C;
  PVRSPGTriggerPos = $0C4;
  PVRSPGHBlankInt = $0C8;
  PVRSPGVBlankInt = $0CC;
  PVRSPGControl = $0D0;
  PVRSPGHBlank = $0D4;
  PVRSPGLoad = $0D8;
  PVRSPGVBlank = $0DC;
  PVRSPGWidth = $0E0;
  PVRVOControl = $0E8;
  PVRVOStartX = $0EC;
  PVRVOStartY = $0F0;
  PVRScalerCtl = $0F4;
  PVRPalRamCtrl = $108;
  PVRSPGStatus = $10C;
  PVRTAOLBase = $124;
  PVRTAISPBase = $128;
  PVRTAOLLimit = $12C;
  PVRTAISPLimit = $130;
  PVRTANextOPB = $134;
  PVRTAITPCurrent = $138;
  PVRTAGlobTileClip = $13C;
  PVRTAAllocCtrl = $140;
  PVRTAListInit = $144;
  PVRTAYUVTexBase = $148;
  PVRTAYUVTexCtrl = $14C;
  PVRTAYUVTexCnt = $150;
  PVRTAListCont = $160;
  PVRTANextOPBInit = $164;

type
  TDCPVRRegs = array[0..$7FF] of Cardinal; // 005F8000..005F9FFF

  TDCPVRSPG = record
    Line: Integer;        // current line in the field
    Field: Integer;       // 0/1 in interlaced modes
    FieldStart: Int64;    // clock at line 0 of this field
    FieldLines: Integer;  // lines in the current field
    Frames: Int64;        // completed fields
  end;

  TDCPVRStartRender = procedure(User: Pointer) of object;

  // Receives TA FIFO data in 32-byte parameters and YUV converter writes.
  TDCTAInput = class
  public
    procedure Reset; virtual; abstract;
    // SOFTRESET: the accelerator's input state only; lists already stored
    // (parameter memory) stay renderable.
    procedure SoftReset; virtual; abstract;
    procedure ListInit; virtual; abstract;
    procedure ListContinue; virtual; abstract;
    procedure Write32Bytes(Data: PCardinal); virtual; abstract;
    procedure WriteYUV(Data: PCardinal; Count: Integer); virtual; abstract;
    procedure SerializeState(Archive: TStateArchive); virtual; abstract;
  end;

  TDCPVR = class
  private
    FMemory: TDCMemory;
    FScheduler: TDCScheduler;
    FInterrupts: TDCInterrupts;
    FFIFO: array[0..7] of Cardinal;
    FFIFOCount: Integer;
    FFrame, FLine: TArray<Cardinal>;
    // RGB555/565 to ARGB for the current depth and concat value.
    FPixels16: TArray<Cardinal>;
    FPixels16Key: Cardinal;
    FFrameWidth, FFrameHeight: Integer;
    FFrameReady: Boolean;
    FPAL: Boolean;
    // Placement of the last scanned-out buffer in the frame (for light guns).
    FScanPadX, FScanPadY, FScanLineStep: Integer;
    function PixelClock: Int64;
    function LineTime(Line: Integer): Int64;
    procedure StartField(At: Int64);
    procedure ScheduleLine;
    procedure LineInterrupts;
    procedure Scanout;
  public
    R: TDCPVRRegs;
    SPG: TDCPVRSPG;
    // Vertical blank starts seen (not serialized: a host-side frame counter).
    VBlankCount: Int64;
    TA: TDCTAInput;
    OnStartRender: TDCPVRStartRender;
    constructor Create(Memory: TDCMemory; Scheduler: TDCScheduler; Interrupts: TDCInterrupts);
    procedure Reset(PAL: Boolean);
    function ReadRegister(Offset: Cardinal): Cardinal;
    procedure WriteRegister(Offset, Value: Cardinal);
    procedure LineEvent;
    // A light gun aimed at frame pixel X, Y: SPG_TRIGGER_POS takes the
    // horizontal and vertical counters of that spot.
    procedure LatchLightGun(X, Y: Integer);
    // TA FIFO bus (00000000..007FFFFF within area 4 polygon path).
    procedure WriteFIFO(Value: Cardinal);
    procedure WriteFIFOBurst(Data: PCardinal; Count: Integer);
    procedure WriteYUV(Data: PCardinal; Count: Integer);
    // The most recent scanned-out field: true once per completed field.
    function TakeFrame(out Pixels: TArray<Cardinal>; out Width, Height: Integer): Boolean;
    procedure SerializeState(Archive: TStateArchive);
    property FrameWidth: Integer read FFrameWidth;
    property FrameHeight: Integer read FFrameHeight;
    property Frame: TArray<Cardinal> read FFrame;
  end;

implementation

constructor TDCPVR.Create(Memory: TDCMemory; Scheduler: TDCScheduler; Interrupts: TDCInterrupts);
begin
  inherited Create;
  FMemory := Memory;
  FScheduler := Scheduler;
  FInterrupts := Interrupts;
  Reset(False);
end;

procedure TDCPVR.Reset(PAL: Boolean);
begin
  FPAL := PAL;
  FillChar(R, SizeOf(R), 0);
  R[PVRID shr 2] := $17FD11DB;
  R[PVRRevision shr 2] := $11;
  // Power-on sync matches the boot ROM's NTSC 480i setup; software replaces it.
  if PAL then
  begin
    R[PVRSPGLoad shr 2] := $0270035F;
    R[PVRSPGVBlankInt shr 2] := $00150136;
    R[PVRSPGVBlank shr 2] := $002D026C;
  end
  else
  begin
    R[PVRSPGLoad shr 2] := $020C0359;
    R[PVRSPGVBlankInt shr 2] := $00150104;
    R[PVRSPGVBlank shr 2] := $00240204;
  end;
  R[PVRSPGControl shr 2] := $00000150;
  R[PVRSPGHBlankInt shr 2] := $031D0000;
  R[PVRFBRSize shr 2] := $0001DCA7; // 640x240 16 bpp fields... until set
  R[PVRVOControl shr 2] := $00000108;
  FFIFOCount := 0;
  FFrameReady := False;
  FFrameWidth := 640;
  FFrameHeight := 480;
  SetLength(FFrame, 640 * 480);
  FillChar(FFrame[0], Length(FFrame) * 4, 0);
  SPG := Default(TDCPVRSPG);
  StartField(FScheduler.Now);
end;

function TDCPVR.PixelClock: Int64;
begin
  // FB_R_CTRL.vclk_div: 1 = 27 MHz (VGA), 0 = 13.5 MHz (TV).
  if (R[PVRFBRCtrl shr 2] and $800000) <> 0 then
    Result := 27000000
  else
    Result := 13500000;
end;

function TDCPVR.LineTime(Line: Integer): Int64;
begin
  var HCount := Int64(R[PVRSPGLoad shr 2] and $3FF) + 1;
  Result := SPG.FieldStart + (Int64(Line) * HCount * DCCPUClock) div PixelClock;
end;

procedure TDCPVR.StartField(At: Int64);
begin
  var VCount := Integer((R[PVRSPGLoad shr 2] shr 16) and $3FF) + 1;
  SPG.FieldStart := At;
  SPG.Line := 0;
  if (R[PVRSPGControl shr 2] and $10) <> 0 then
  begin
    // Interlace: two fields per frame; the first takes the extra half line.
    SPG.Field := SPG.Field xor 1;
    SPG.FieldLines := VCount div 2 + (VCount and 1) * (1 - SPG.Field);
  end
  else
  begin
    SPG.Field := 0;
    SPG.FieldLines := VCount;
  end;
  if SPG.FieldLines < 16 then
    SPG.FieldLines := 16;
  LineInterrupts;
  ScheduleLine;
end;

procedure TDCPVR.ScheduleLine;
begin
  FScheduler.Schedule(TDCEvent.SPGLine, LineTime(SPG.Line + 1));
end;

procedure TDCPVR.LineEvent;
begin
  Inc(SPG.Line);
  if SPG.Line >= SPG.FieldLines then
  begin
    Inc(SPG.Frames);
    StartField(LineTime(SPG.FieldLines));
    Exit;
  end;
  LineInterrupts;
  ScheduleLine;
end;

// The interrupts of the current line, line 0 included (KallistiOS of 2016
// takes its vertical blank from an HBlank interrupt at line 0).
procedure TDCPVR.LineInterrupts;
begin
  var VBlankInt := R[PVRSPGVBlankInt shr 2];
  if SPG.Line = Integer(VBlankInt and $3FF) then
  begin
    Scanout;
    Inc(VBlankCount);
    FInterrupts.RaiseNormal(HollyVBlankIn);
  end;
  if SPG.Line = Integer((VBlankInt shr 16) and $3FF) then
    FInterrupts.RaiseNormal(HollyVBlankOut);
  var HBlankInt := R[PVRSPGHBlankInt shr 2];
  var Compare := Integer(HBlankInt and $3FF);
  case (HBlankInt shr 12) and 3 of
    0:
      if SPG.Line = Compare then
        FInterrupts.RaiseNormal(HollyHBlank);
    1:
      if (Compare > 0) and (SPG.Line mod Compare = 0) then
        FInterrupts.RaiseNormal(HollyHBlank);
    2:
      FInterrupts.RaiseNormal(HollyHBlank);
  end;
end;

procedure TDCPVR.LatchLightGun(X, Y: Integer);
begin
  // Frame pixels advance the horizontal counter by one pixel clock; a field
  // line holds two frame lines when interlaced or line doubled. The picture
  // starts at VO_STARTX/VO_STARTY.
  var H := Integer(R[PVRVOStartX shr 2] and $3FF) + (X - FScanPadX);
  var V := Integer(R[PVRVOStartY shr 2] and $3FF) + (Y - FScanPadY) div Max(1, FScanLineStep);
  R[PVRSPGTriggerPos shr 2] := (Cardinal(EnsureRange(V, 0, $3FF)) shl 16) or Cardinal(EnsureRange(H, 0, $3FF));
end;

procedure TDCPVR.Scanout;
begin
  var Ctrl := R[PVRFBRCtrl shr 2];
  var Size := R[PVRFBRSize shr 2];
  var Words := Integer(Size and $3FF) + 1;
  var Lines := Integer((Size shr 10) and $3FF) + 1;
  var Modulus := Integer((Size shr 20) and $3FF);
  var Depth := (Ctrl shr 2) and 3;
  var Concat := (Ctrl shr 4) and 7;
  var Width: Integer;
  case Depth of
    0, 1: Width := Words * 2;
    2: Width := Words * 4 div 3;
  else
    Width := Words;
  end;
  var Interlaced := (R[PVRSPGControl shr 2] and $10) <> 0;
  // Each line shown twice (fb_line_double) or each pixel (pixel_double, for
  // half-width buffers).
  var LineDouble := not Interlaced and ((Ctrl and 2) <> 0);
  var PixelDouble := ((R[PVRVOControl shr 2] and $100) <> 0) and (Width <= 400);
  var Height := Lines;
  if Interlaced or LineDouble then
    Height := Lines * 2;
  if (Width < 16) or (Width > 1024) or (Height < 16) or (Height > 1024) then
  begin
    Width := 640;
    Height := 480;
    PixelDouble := False;
  end;
  // Buffers a few lines or pixels short of the standard picture sit in it
  // with the border colour around, so the output size stays put.
  var OutWidth := Width;
  if PixelDouble then
    OutWidth := Width * 2;
  var OutHeight := Height;
  if (OutHeight >= 470) and (OutHeight < 480) then
    OutHeight := 480;
  if (OutWidth >= 630) and (OutWidth < 640) then
    OutWidth := 640;
  var PadX := (OutWidth - Width * (1 + Ord(PixelDouble))) div 2;
  var PadY := (OutHeight - Height) div 2;
  FScanPadX := PadX;
  FScanPadY := PadY;
  FScanLineStep := 1;
  if Interlaced or LineDouble then
    FScanLineStep := 2;
  if (OutWidth <> FFrameWidth) or (OutHeight <> FFrameHeight) then
  begin
    FFrameWidth := OutWidth;
    FFrameHeight := OutHeight;
    SetLength(FFrame, OutWidth * OutHeight);
  end;
  var Border := $FF000000 or (R[PVRBorderColor shr 2] and $FFFFFF);
  if ((Ctrl and 1) = 0) or (PadX > 0) or (PadY > 0) then
    for var I := 0 to High(FFrame) do
      FFrame[I] := Border;
  if (Ctrl and 1) = 0 then
  begin
    FFrameReady := True;
    Exit;
  end;
  var Stride := (Words + Modulus - 1) * 4;
  // A render in flight finishes before its buffer is shown.
  var Span := Cardinal(Lines) * Cardinal(Stride) + Cardinal(Width) * 4;
  FMemory.Observe(R[PVRFBRSOF1 shr 2] and $7FFFFF, Span);
  if Interlaced then
    FMemory.Observe(R[PVRFBRSOF2 shr 2] and $7FFFFF, Span);
  var VRAM := FMemory.VRAM;
  if Length(FLine) < Width then
    SetLength(FLine, Width);
  if (Depth <= 1) and ((Length(FPixels16) = 0) or (FPixels16Key <> Depth * 8 + Concat)) then
  begin
    SetLength(FPixels16, 65536);
    for var P := 0 to 65535 do
    begin
      var RR, GG, BB: Cardinal;
      if Depth = 0 then
      begin
        RR := ((P shr 10) and 31) shl 3 or Concat;
        GG := ((P shr 5) and 31) shl 3 or Concat;
      end
      else
      begin
        RR := ((P shr 11) and 31) shl 3 or Concat;
        GG := ((P shr 5) and 63) shl 2 or (Concat shr 1);
      end;
      BB := (P and 31) shl 3 or Concat;
      FPixels16[P] := $FF000000 or (RR shl 16) or (GG shl 8) or BB;
    end;
    FPixels16Key := Depth * 8 + Concat;
  end;
  for var Y := 0 to Height - 1 do
  begin
    var Base: Cardinal;
    if Interlaced then
    begin
      if (Y and 1) = 0 then
        Base := R[PVRFBRSOF1 shr 2]
      else
        Base := R[PVRFBRSOF2 shr 2];
      Base := Base + Cardinal((Y shr 1) * Stride);
    end
    else if LineDouble then
      Base := R[PVRFBRSOF1 shr 2] + Cardinal((Y shr 1) * Stride)
    else
      Base := R[PVRFBRSOF1 shr 2] + Cardinal(Y * Stride);
    // Straight into the picture unless doubled.
    var Row := (Y + PadY) * OutWidth + PadX;
    var Line: PCardinal := @FLine[0];
    if not PixelDouble then
      Line := @FFrame[Row];
    case Depth of
      0, 1:
        begin
          // 16-bit pixels through a table of the 65536 colours.
          var Table: PCardinal := @FPixels16[0];
          var First := Base and $7FFFFE;
          if First + Cardinal(Width) * 2 <= DCVRAMSize then
          begin
            // The line does not wrap around VRAM.
            var Src: PWord := PWord(VRAM + First);
            for var X := 0 to Width - 1 do
              Line[X] := Table[Src[X]];
          end
          else
            for var X := 0 to Width - 1 do
              Line[X] := Table[PWord(VRAM + ((Base + Cardinal(X) * 2) and $7FFFFE))^];
        end;
      2:
        for var X := 0 to Width - 1 do
        begin
          var A := Base + Cardinal(X) * 3;
          var BB := (VRAM + (A and $7FFFFF))^;
          var GG := (VRAM + ((A + 1) and $7FFFFF))^;
          var RR := (VRAM + ((A + 2) and $7FFFFF))^;
          Line[X] := $FF000000 or (Cardinal(RR) shl 16) or (Cardinal(GG) shl 8) or Cardinal(BB);
        end;
    else
      for var X := 0 to Width - 1 do
        Line[X] := $FF000000 or (PCardinal(VRAM + ((Base + Cardinal(X) * 4) and $7FFFFC))^ and $FFFFFF);
    end;
    // Into the picture, doubled.
    if PixelDouble then
      for var X := 0 to Width - 1 do
      begin
        FFrame[Row + X * 2] := FLine[X];
        FFrame[Row + X * 2 + 1] := FLine[X];
      end;
  end;
  FFrameReady := True;
end;

function TDCPVR.TakeFrame(out Pixels: TArray<Cardinal>; out Width, Height: Integer): Boolean;
begin
  Result := FFrameReady;
  FFrameReady := False;
  Pixels := FFrame;
  Width := FFrameWidth;
  Height := FFrameHeight;
end;

function TDCPVR.ReadRegister(Offset: Cardinal): Cardinal;
begin
  Offset := Offset and $1FFC;
  case Offset of
    PVRSPGStatus:
      begin
        // Line, field, blanking and sync from the current position.
        var Line := SPG.Line;
        var VBlank := R[PVRSPGVBlank shr 2];
        Result := Cardinal(Line) and $3FF;
        Result := Result or (Cardinal(SPG.Field) shl 10);
        if (Line >= Integer(VBlank and $3FF)) or (Line < Integer((VBlank shr 16) and $3FF)) then
          Result := Result or $800 or $2000;
        var HCount := Int64(R[PVRSPGLoad shr 2] and $3FF) + 1;
        var LineStart := LineTime(Line);
        var Pixel := ((FScheduler.Now - LineStart) * PixelClock) div DCCPUClock;
        if Pixel >= HCount - 64 then
          Result := Result or $1000;
      end;
    PVRTAITPCurrent:
      Result := R[Offset shr 2];
  else
    Result := R[Offset shr 2];
  end;
end;

procedure TDCPVR.WriteRegister(Offset, Value: Cardinal);
begin
  Offset := Offset and $1FFC;
  case Offset of
    PVRID, PVRRevision, PVRSPGStatus:
      ;
    PVRSoftReset:
      begin
        R[Offset shr 2] := Value and 7;
        if (Value and 1) <> 0 then
          TA.SoftReset;
      end;
    PVRStartRender:
      if Assigned(OnStartRender) then
        OnStartRender(Self);
    PVRTAListInit:
      if (Value and $80000000) <> 0 then
      begin
        R[PVRTANextOPB shr 2] := R[PVRTANextOPBInit shr 2];
        R[PVRTAITPCurrent shr 2] := R[PVRTAISPBase shr 2];
        TA.ListInit;
      end;
    PVRTAListCont:
      if (Value and $80000000) <> 0 then
        TA.ListContinue;
    PVRTAYUVTexBase, PVRTAYUVTexCtrl:
      begin
        R[Offset shr 2] := Value;
        R[PVRTAYUVTexCnt shr 2] := 0;
      end;
    PVRSPGLoad, PVRSPGControl, PVRFBRCtrl:
      begin
        R[Offset shr 2] := Value;
        // Timing changes take effect from the next line.
        if SPG.Line + 1 >= SPG.FieldLines then
          ScheduleLine;
      end;
  else
    R[Offset shr 2] := Value;
  end;
end;

procedure TDCPVR.WriteFIFO(Value: Cardinal);
begin
  FFIFO[FFIFOCount] := Value;
  Inc(FFIFOCount);
  if FFIFOCount = 8 then
  begin
    FFIFOCount := 0;
    TA.Write32Bytes(@FFIFO[0]);
  end;
end;

procedure TDCPVR.WriteFIFOBurst(Data: PCardinal; Count: Integer);
begin
  while Count > 0 do
  begin
    if (FFIFOCount = 0) and (Count >= 8) then
    begin
      TA.Write32Bytes(Data);
      Inc(Data, 8);
      Dec(Count, 8);
      Continue;
    end;
    WriteFIFO(Data^);
    Inc(Data);
    Dec(Count);
  end;
end;

procedure TDCPVR.WriteYUV(Data: PCardinal; Count: Integer);
begin
  TA.WriteYUV(Data, Count);
end;

procedure TDCPVR.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(R, SizeOf(R));
  Archive.Field(SPG, SizeOf(SPG));
  Archive.Field(FFIFO, SizeOf(FFIFO));
  Archive.Field(FFIFOCount, SizeOf(FFIFOCount));
  if Archive.Loading then
  begin
    if (FFIFOCount < 0) or (FFIFOCount > 7) or (SPG.Line < 0) or (SPG.FieldLines < 16) or
      (SPG.FieldLines > 1100) or (SPG.Line > SPG.FieldLines) then
      raise EReadError.Create('Dreamcast snapshot PVR state');
  end;
  TA.SerializeState(Archive);
end;

end.
