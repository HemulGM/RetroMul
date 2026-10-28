unit DC.GDROM.HLE;

// High-level GD-ROM system calls (vector 8C0000BC, superfunction 0): the
// boot ROM's command queue (REQ_CMD, GET_CMD_STAT, EXEC_SERVER), drive
// status, sector mode, and the streamed DMA/PIO transfer interface. Commands
// read the disc image directly; CD-DA commands drive the GD-ROM audio state.
// Interface: KallistiOS syscalls.c/cdrom.h, Marcus Comstedt's syscall notes.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, HW.SH4, DC.Types, DC.Memory,
  DC.Interrupts, DC.Disc, DC.GDROM, DC.Boot;

type
  TDCBusReader = function(Address: Cardinal; Size: Integer): UInt64 of object;

  TDCBusWriter = procedure(Address: Cardinal; Value: UInt64; Size: Integer) of object;

  TDCGDWords = array[0..3] of Cardinal;

  TDCGDROMHLEState = record
    Status: Integer;          // 0 OK, 1 BUSY, 2 COMPLETE, 3 CONTINUE, -1 ERR
    Command: Cardinal;
    RequestId, NextId: Cardinal;
    Params: TDCGDWords;
    Result: TDCGDWords;
    CurrentSector: Cardinal;  // FAD
    StreamSector: Cardinal;   // FAD of the next streamed sector
    StreamBytes: Cardinal;    // bytes left in the stream
    StreamTotal: Cardinal;
    StreamOffset: Cardinal;   // offset in the current sector
    PIOCallback, PIOArgument: Cardinal;
    DMACallback, DMAArgument: Cardinal;
    SectorMode: TDCGDWords;
    DriveMode: TDCGDWords; // speed, standby, read flags, retry
  end;

  TDCGDROMHLE = class(TDCGDROMSyscalls)
  private
    FDrive: TDCGDROM;
    FMemory: TDCMemory;
    FInterrupts: TDCInterrupts;
    FRead: TDCBusReader;
    FWrite: TDCBusWriter;
    FCPU: TSH4;
    procedure Store32(Address, Value: Cardinal);
    function Load32(Address: Cardinal): Cardinal;
    // DMA writes physical memory; the CPU's (PIO) view goes through the MMU.
    procedure StoreBytes(Address: Cardinal; Data: PByte; Count: Integer; DMA: Boolean = False);
    procedure ReadSectors(FAD, Count, Address: Cardinal; DMA: Boolean);
    procedure Execute;
    procedure Serve;
    procedure StreamTransfer(Address, Count: Cardinal; DMA: Boolean);
    function DiscPresent: Boolean;
  public
    S: TDCGDROMHLEState;
    constructor Create(Drive: TDCGDROM; Memory: TDCMemory; Interrupts: TDCInterrupts; Read: TDCBusReader; Write: TDCBusWriter);
    procedure Reset; override;
    function Call(CPU: TSH4; Memory: TDCMemory): Boolean; override;
    procedure SerializeState(Archive: TStateArchive); override;
    // The lid opened: a command in progress ends with "not ready".
    procedure LidOpened;
    function CurrentDisc: TDCDisc; override;
  end;

implementation

const
  GDC_OK = 0;
  GDC_BUSY = 1;
  GDC_COMPLETE = 2;
  GDC_CONTINUE = 3;
  GDC_ERR = -1;
  CMD_CHECK_LICENSE = 2;
  CMD_PIOREAD = 16;
  CMD_DMAREAD = 17;
  CMD_GETTOC = 18;
  CMD_GETTOC2 = 19;
  CMD_PLAY = 20;
  CMD_PLAY2 = 21;
  CMD_PAUSE = 22;
  CMD_RELEASE = 23;
  CMD_INIT = 24;
  CMD_SEEK = 27;
  CMD_REQ_MODE = 30;
  CMD_SET_MODE = 31;
  CMD_STOP = 33;
  CMD_GETSCD = 34;
  CMD_GETSES = 35;
  CMD_REQ_STAT = 36;
  CMD_DMAREAD_STREAM_EX = 38;
  CMD_PIOREAD_STREAM_EX = 39;
  CMD_GET_VERS = 40;
  // Pseudo command: a PIO transfer queued by REQ_PIO_TRANS.
  CMD_PIO_TRANSFER = $100;

constructor TDCGDROMHLE.Create(Drive: TDCGDROM; Memory: TDCMemory; Interrupts: TDCInterrupts; Read: TDCBusReader; Write: TDCBusWriter);
begin
  inherited Create;
  FDrive := Drive;
  FMemory := Memory;
  FInterrupts := Interrupts;
  FRead := Read;
  FWrite := Write;
  Reset;
end;

procedure TDCGDROMHLE.Reset;
begin
  S := Default(TDCGDROMHLEState);
  S.RequestId := $FFFFFFFF;
  S.NextId := 1;
  S.SectorMode[1] := 8192;
  S.SectorMode[2] := 2048;
  S.SectorMode[3] := 2048;
  S.DriveMode[0] := 0;
  S.DriveMode[1] := $B4;
  S.DriveMode[2] := $19;
  S.DriveMode[3] := 8;
end;

procedure TDCGDROMHLE.LidOpened;
begin
  S.StreamBytes := 0;
  if (S.Status = GDC_BUSY) or (S.Status = GDC_CONTINUE) then
  begin
    S.Status := GDC_ERR;
    S.Result[0] := 2;
  end;
  S.CurrentSector := 0;
end;

function TDCGDROMHLE.CurrentDisc: TDCDisc;
begin
  FDrive.Settle;
  Result := FDrive.Disc;
end;

function TDCGDROMHLE.DiscPresent: Boolean;
begin
  Result := (FDrive.Disc <> nil) and FDrive.Disc.HasBootTrack;
end;

procedure TDCGDROMHLE.Store32(Address, Value: Cardinal);
begin
  FCPU.StoreVirtual(Address, Value, 4);
  if FCPU.AccessFaulted then
    raise EDCSyscallFault.Create('');
end;

function TDCGDROMHLE.Load32(Address: Cardinal): Cardinal;
begin
  Result := FCPU.LoadVirtual(Address, 4);
  if FCPU.AccessFaulted then
    raise EDCSyscallFault.Create('');
end;

procedure TDCGDROMHLE.StoreBytes(Address: Cardinal; Data: PByte; Count: Integer; DMA: Boolean);
begin
  while Count > 0 do
  begin
    // Translated a 4 KiB page at a time.
    var Chunk := Count;
    var Physical := Address and $1FFFFFFF;
    if not DMA then
    begin
      if Chunk > $1000 - Integer(Address and $FFF) then
        Chunk := $1000 - Integer(Address and $FFF);
      if not FCPU.TranslateOrFault(Address, True, Physical) then
        raise EDCSyscallFault.Create('');
    end;
    // System RAM directly; other targets byte by byte.
    if (Physical >= $0C000000) and (Physical < $10000000) then
    begin
      var Offset := Physical and (DCRAMSize - 1);
      var First := Chunk;
      if Int64(Offset) + Chunk > DCRAMSize then
        First := DCRAMSize - Integer(Offset);
      Move(Data^, (FMemory.RAM + Offset)^, First);
      if First < Chunk then
        Move(Data[First], FMemory.RAM^, Chunk - First);
      FMemory.TouchRAM(Offset, Chunk);
    end
    else if DMA then
      for var I := 0 to Chunk - 1 do
        FWrite(Physical + Cardinal(I), Data[I], 1)
    else
      for var I := 0 to Chunk - 1 do
      begin
        FCPU.StoreVirtual(Address + Cardinal(I), Data[I], 1);
        if FCPU.AccessFaulted then
          raise EDCSyscallFault.Create('');
      end;
    Inc(Address, Chunk);
    Inc(Data, Chunk);
    Dec(Count, Chunk);
  end;
end;

procedure TDCGDROMHLE.ReadSectors(FAD, Count, Address: Cardinal; DMA: Boolean);
var
  Buffer: array[0..2047] of Byte;
begin
  for var I := 0 to Integer(Count) - 1 do
  begin
    FDrive.Disc.ReadData(Integer(FAD) - 150 + I, @Buffer[0]);
    StoreBytes(Address + Cardinal(I) * 2048, @Buffer[0], 2048, DMA);
  end;
  S.CurrentSector := FAD + Count - 1;
end;

procedure TDCGDROMHLE.StreamTransfer(Address, Count: Cardinal; DMA: Boolean);
var
  Buffer: array[0..2047] of Byte;
begin
  // Continues a stream at byte granularity across sectors.
  if Count > S.StreamBytes then
    Count := S.StreamBytes;
  while Count > 0 do
  begin
    FDrive.Disc.ReadData(Integer(S.StreamSector) - 150, @Buffer[0]);
    var Chunk := 2048 - S.StreamOffset;
    if Chunk > Count then
      Chunk := Count;
    StoreBytes(Address, @Buffer[S.StreamOffset], Chunk, DMA);
    Inc(Address, Chunk);
    Dec(Count, Chunk);
    if not DMA then
    begin
      // A PIO transfer stopped by an MMU exception continues from here.
      S.Params[0] := Address;
      S.Params[1] := Count;
    end;
    Dec(S.StreamBytes, Chunk);
    Inc(S.StreamOffset, Chunk);
    if S.StreamOffset = 2048 then
    begin
      S.StreamOffset := 0;
      S.CurrentSector := S.StreamSector;
      Inc(S.StreamSector);
    end;
  end;
  S.Result[2] := S.StreamTotal - S.StreamBytes;
  if DMA then
  begin
    if S.StreamBytes = 0 then
      S.Status := GDC_COMPLETE;
    FInterrupts.RaiseNormal(HollyGDDMA);
  end
  else if S.PIOCallback <> 0 then
  begin
    // The PIO callback receives its argument and returns to the caller.
    FCPU.S.R[4] := S.PIOArgument;
    FCPU.S.PC := S.PIOCallback;
  end;
end;

procedure TDCGDROMHLE.Execute;
begin
  var P := S.Params;
  case S.Command of
    CMD_CHECK_LICENSE, CMD_INIT:
      begin
        S.StreamBytes := 0;
        FDrive.StopCDDA;
      end;
    CMD_PIOREAD, CMD_DMAREAD:
      begin
        if not DiscPresent then
        begin
          S.Status := GDC_ERR;
          S.Result[0] := 2;
          Exit;
        end;
        FDrive.StopCDDA;
        if S.Command = CMD_DMAREAD then
        begin
          ReadSectors(P[0] and $FFFFFF, P[1], P[2], True);
          S.Result[2] := P[1] * 2048;
          FInterrupts.RaiseNormal(HollyGDDMA);
        end
        else
          // Sector by sector with the parameters following the progress, so
          // that a read stopped by an MMU exception continues from there.
          while S.Params[1] > 0 do
          begin
            ReadSectors(S.Params[0] and $FFFFFF, 1, S.Params[2], False);
            Inc(S.Params[0]);
            Dec(S.Params[1]);
            Inc(S.Params[2], 2048);
            Inc(S.Result[2], 2048);
          end;
      end;
    CMD_GETTOC, CMD_GETTOC2:
      begin
        var Words: TArray<Cardinal>;
        if DiscPresent and FDrive.Disc.TOC(Integer(P[0] and 1), Words) then
          for var I := 0 to 101 do
            Store32(P[1] + Cardinal(I) * 4, Words[I]);
      end;
    CMD_PLAY:
      if DiscPresent then
        FDrive.PlayTracks(P[0], P[1], P[2])
      else
        S.Status := GDC_ERR;
    CMD_PLAY2:
      FDrive.PlaySectors(P[0] and $FFFFFF, P[1] and $FFFFFF, P[2]);
    CMD_PAUSE:
      FDrive.PauseCDDA;
    CMD_RELEASE:
      FDrive.ResumeCDDA;
    CMD_STOP:
      FDrive.StopCDDA;
    CMD_SEEK:
      FDrive.SeekCDDA(P[0] and $FFFFFF);
    CMD_REQ_MODE:
      begin
        for var I := 0 to 3 do
          Store32(P[0] + Cardinal(I) * 4, S.DriveMode[I]);
        S.Result[2] := 10;
      end;
    CMD_SET_MODE:
      begin
        S.DriveMode := P;
        S.Result[2] := 10;
      end;
    CMD_GETSCD:
      begin
        // Format 1 (Q channel): audio status, length, then the Q data.
        var Size := P[1];
        if Size > 100 then
          Size := 100;
        var Data: array[0..99] of Byte;
        FillChar(Data, SizeOf(Data), 0);
        var FAD := FDrive.CDDAPosition;
        if FAD = 0 then
          FAD := S.CurrentSector;
        Data[1] := FDrive.AudioStatus;
        Data[3] := Byte(Size);
        if (P[0] = 1) and DiscPresent then
        begin
          var Track := FDrive.Disc.TrackOf(Integer(FAD) - 150);
          var Control := 4;
          if (Track > 0) and FDrive.Disc.Image.Track(Track).Audio then
            Control := 0;
          Data[4] := Byte((Control shl 4) or 1);
          Data[5] := Byte(Track);
          Data[6] := 1;
          var Relative := 0;
          if Track > 0 then
            Relative := Integer(FAD) - 150 - FDrive.Disc.Image.Track(Track).StartLBA;
          if Relative < 0 then
            Relative := 0;
          Data[7] := Byte(Relative shr 16);
          Data[8] := Byte(Relative shr 8);
          Data[9] := Byte(Relative);
          Data[11] := Byte(FAD shr 16);
          Data[12] := Byte(FAD shr 8);
          Data[13] := Byte(FAD);
        end;
        StoreBytes(P[2], @Data[0], Size);
        S.Result[2] := Size;
      end;
    CMD_GETSES:
      begin
        // Session information: status, session count or start FAD.
        var Data: array[0..5] of Byte;
        FillChar(Data, SizeOf(Data), 0);
        Data[0] := FDrive.DriveStatus;
        if DiscPresent then
        begin
          var Sessions := 1;
          for var T := 1 to FDrive.Disc.Image.TrackCount do
            if FDrive.Disc.Image.Track(T).Session > Sessions then
              Sessions := FDrive.Disc.Image.Track(T).Session;
          var FAD: Cardinal := 0;
          if P[0] = 0 then
          begin
            Data[2] := Byte(Sessions);
            FAD := Cardinal(FDrive.Disc.Image.LeadOut + 150);
          end
          else
            for var T := 1 to FDrive.Disc.Image.TrackCount do
              if FDrive.Disc.Image.Track(T).Session = Integer(P[0]) then
              begin
                Data[2] := Byte(T);
                FAD := Cardinal(FDrive.Disc.Image.Track(T).StartLBA + 150);
                Break;
              end;
          Data[3] := Byte(FAD shr 16);
          Data[4] := Byte(FAD shr 8);
          Data[5] := Byte(FAD);
        end;
        StoreBytes(P[2], @Data[0], 6);
        S.Result[2] := 6;
      end;
    CMD_REQ_STAT:
      begin
        var FAD := FDrive.CDDAPosition;
        if FAD = 0 then
          FAD := S.CurrentSector;
        var Track := 0;
        var Control: Cardinal := 4;
        if DiscPresent then
        begin
          Track := FDrive.Disc.TrackOf(Integer(FAD) - 150);
          if (Track > 0) and FDrive.Disc.Image.Track(Track).Audio then
            Control := 0;
        end;
        Store32(P[0], (Cardinal(FDrive.S.CDDA.Repeats) shl 8) or FDrive.DriveStatus);
        Store32(P[1], Cardinal(Track));
        Store32(P[2], (Cardinal(1) shl 28) or (Control shl 24) or (FAD and $FFFFFF));
        Store32(P[3], 1);
        S.Result[2] := 10;
      end;
    CMD_DMAREAD_STREAM_EX, CMD_PIOREAD_STREAM_EX:
      begin
        FDrive.StopCDDA;
        S.Status := GDC_CONTINUE;
        S.StreamSector := P[0] and $FFFFFF;
        S.StreamBytes := P[1] * 2048;
        S.StreamTotal := S.StreamBytes;
        S.StreamOffset := 0;
        S.Result[2] := 0;
        S.Result[3] := 0;
        Exit;
      end;
    CMD_PIO_TRANSFER:
      begin
        StreamTransfer(S.Params[0], S.Params[1], False);
        S.Command := CMD_PIOREAD_STREAM_EX;
        if S.StreamBytes = 0 then
          S.Status := GDC_COMPLETE;
        Exit;
      end;
    CMD_GET_VERS:
      begin
        var Version: AnsiString := 'GDC Version 1.10 1999-03-31 ';
        StoreBytes(P[0], PByte(PAnsiChar(Version)), Length(Version));
      end;
  end;
  if S.Status = GDC_BUSY then
    S.Status := GDC_COMPLETE;
end;

function TDCGDROMHLE.Call(CPU: TSH4; Memory: TDCMemory): Boolean;
begin
  FCPU := CPU;
  Result := True;
  FDrive.Settle;
  // A call that makes the CPU take an MMU exception (EDCSyscallFault) runs
  // again: registers and state change only after the accesses that can
  // fail, except for PIO transfers, which keep their progress.
  Serve;
end;

procedure TDCGDROMHLE.Serve;
begin
  var R: ^TSH4Registers := @FCPU.S.R;
  // Superfunction -1: MISC (vector initialization and handlers).
  if R[6] <> 0 then
  begin
    R[0] := 0;
    Exit;
  end;
  case R[7] of
    0:
      // REQ_CMD: queue a command; parameters are four words at R5.
      if S.Status <> GDC_OK then
        R[0] := 0
      else
      begin
        for var I := 0 to 3 do
          if R[5] <> 0 then
            S.Params[I] := Load32(R[5] + Cardinal(I) * 4)
          else
            S.Params[I] := 0;
        FillChar(S.Result, SizeOf(S.Result), 0);
        if (S.NextId = 0) or (S.NextId = $FFFFFFFF) then
          S.NextId := 1;
        S.RequestId := S.NextId;
        Inc(S.NextId);
        R[0] := S.RequestId;
        S.Status := GDC_BUSY;
        S.Command := R[4];
        S.StreamBytes := 0;
      end;
    1:
      begin
        // GET_CMD_STAT: extended status at R5.
        for var I := 0 to 3 do
          Store32(R[5] + Cardinal(I) * 4, S.Result[I]);
        if (S.Status = GDC_OK) or (S.Status = GDC_BUSY) then
          R[0] := Cardinal(S.Status)
        else if R[4] <> S.RequestId then
          R[0] := GDC_OK
        else
        begin
          R[0] := Cardinal(S.Status);
          if (S.Status = GDC_CONTINUE) and (S.StreamBytes = 0) then
            S.Status := GDC_COMPLETE
          else if S.Status <> GDC_CONTINUE then
          begin
            S.Status := GDC_OK;
            S.RequestId := $FFFFFFFF;
          end;
        end;
      end;
    2:
      begin
        // EXEC_SERVER: queued commands run here. The boot ROM reads the
        // drive status, which acknowledges its interrupt.
        FDrive.SetInterrupt(False);
        if (S.Status = GDC_BUSY) or ((S.Status = GDC_CONTINUE) and (S.Command = CMD_PIO_TRANSFER)) then
          Execute;
      end;
    3:
      begin
        Reset;
        R[0] := 0;
      end;
    4:
      begin
        // GET_DRV_STAT: drive status (6 with the lid open) and disc type at R4.
        if DiscPresent then
        begin
          var Status := FDrive.DriveStatus;
          if S.Status = GDC_CONTINUE then
            Status := 3;
          Store32(R[4], Status);
          Store32(R[4] + 4, FDrive.Disc.DiscType);
        end
        else
        begin
          Store32(R[4], FDrive.DriveStatus);
          Store32(R[4] + 4, 0);
        end;
        R[0] := 0;
      end;
    5:
      begin
        // G1_DMA_END: completion callback for streamed DMA.
        S.DMACallback := R[4];
        S.DMAArgument := R[5];
        FInterrupts.AcknowledgeNormal(Cardinal(1) shl HollyGDDMA);
        R[0] := 0;
      end;
    6:
      begin
        // REQ_DMA_TRANS: buffer and size at R5.
        var Address := Load32(R[5]);
        var Size := Load32(R[5] + 4);
        if (S.Status <> GDC_CONTINUE) or (Size = 0) or (Size > S.StreamBytes) then
          R[0] := Cardinal(GDC_ERR)
        else
        begin
          StreamTransfer(Address, Size, True);
          R[0] := 0;
        end;
      end;
    7, 13:
      begin
        // CHECK_DMA_TRANS / CHECK_PIO_TRANS: bytes left in the stream.
        Store32(R[5], S.StreamBytes);
        if S.Status = GDC_CONTINUE then
          R[0] := 0
        else if R[7] = 7 then
          R[0] := GDC_BUSY
        else
          R[0] := Cardinal(GDC_ERR);
      end;
    8:
      // ABORT_COMMAND.
      if (R[4] = S.RequestId) and (S.Status in [GDC_BUSY, GDC_COMPLETE, GDC_CONTINUE]) then
      begin
        S.StreamBytes := 0;
        S.Status := GDC_OK;
        R[0] := 0;
      end
      else
        R[0] := Cardinal(GDC_ERR);
    9:
      begin
        S.RequestId := $FFFFFFFF;
        S.Status := GDC_OK;
      end;
    10:
      begin
        // CHANGE_DATA_TYPE: word 0 selects set (0) or query (1).
        if Load32(R[4]) = 0 then
          for var I := 0 to 3 do
            S.SectorMode[I] := Load32(R[4] + Cardinal(I) * 4)
        else
          for var I := 1 to 3 do
            Store32(R[4] + Cardinal(I) * 4, S.SectorMode[I]);
        R[0] := 0;
      end;
    11:
      begin
        S.PIOCallback := R[4];
        S.PIOArgument := R[5];
        R[0] := 0;
      end;
    12:
      begin
        // REQ_PIO_TRANS: runs from the next EXEC_SERVER.
        var Address := Load32(R[5]);
        var Size := Load32(R[5] + 4);
        if (S.Status <> GDC_CONTINUE) or (Size > S.StreamBytes) then
          R[0] := Cardinal(GDC_ERR)
        else
        begin
          S.Params[0] := Address;
          S.Params[1] := Size;
          S.Command := CMD_PIO_TRANSFER;
          R[0] := 0;
          // The drive interrupts when the data is ready; Windows CE serves
          // the transfer from its interrupt thread.
          FDrive.SetInterrupt(True);
        end;
      end;
  else
    R[0] := 0;
  end;
end;

procedure TDCGDROMHLE.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(S, SizeOf(S));
  if Archive.Loading and ((S.Status < -1) or (S.Status > 3) or (S.StreamOffset > 2048)) then
    raise EReadError.Create('Dreamcast snapshot GD-ROM system call state');
end;

end.

