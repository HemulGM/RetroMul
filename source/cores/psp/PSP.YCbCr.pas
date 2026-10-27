unit PSP.YCbCr;

// Native PSP eight-buffer YCbCr layout. Layout reference: PPSSPP Project,
// Core/HLE/sceVideocodec.cpp and Jpcsp sceMpeg.java (GPL-2.0+ / GPL-3.0+).
// This port is supplied under GPL-3.0-or-later; see PSP.PRX-LICENSE.md.
{$Q-}{$R-}{$POINTERMATH ON}
interface

uses
  System.SysUtils, PSP.Memory, Video.AVC.Types;

function PSPYCbCrSize(Mode, Width, Height: Cardinal): Cardinal;

procedure InitPSPYCbCr(Memory: TPSPMemory; Address, Mode, Width, Height: Cardinal);

procedure WritePSPYCbCr(Memory: TPSPMemory; Address: Cardinal; const Frame: TVideoFrame);

function ReadPSPYCbCr(Memory: TPSPMemory; Address: Cardinal): TVideoFrame;

implementation

function PSPYCbCrSize(Mode, Width, Height: Cardinal): Cardinal;
begin
  Result := 0;
  if Mode = 2 then
    Exit(128);
  if (Width < 32) or (Width > 480) or (Height = 0) or (Height > 272) or ((Width or Height) and 15 <> 0) then
    Exit;
  case Mode of
    1:
      Result := 128 + Width * Height * 3 div 2;
    3:
      Result := Width * Height * 3 div 2
  end;
end;

function BufferSize(Width, Height: Integer; Index: Integer): Integer;
begin
  if Index and 1 = 0 then
    Result := ((Width + 16) div 32) * (Height div 2) * 16
  else
    Result := (Width div 32) * (Height div 2) * 16;
  if Index >= 4 then
    Result := Result div 2;
end;

procedure InitPSPYCbCr(Memory: TPSPMemory; Address, Mode, Width, Height: Cardinal);
const
  Order: array[0..7] of Integer = (0, 2, 4, 6, 1, 3, 5, 7);
begin
  var Size := PSPYCbCrSize(Mode, Width, Height);
  if (Size = 0) or not Memory.IsValid(Address, Size) then
    raise EPSPMemory.Create('PSP MPEG invalid YCbCr buffer');
  if Mode = 3 then
  begin
    Memory.Fill(Address, Width * Height, 16);
    Memory.Fill(Address + Width * Height, Width * Height div 2, 128);
    Exit;
  end;
  Memory.Zero(Address, 128);
  Memory.Write32(Address, Height div 16);
  Memory.Write32(Address + 4, Width div 16);
  if Mode = 2 then
  begin
    for var I := 0 to 7 do
      Memory.Write32(Address + 16 + Cardinal(I) * 4, 2);
    Exit
  end;
  var At := Address + 128;
  for var I in Order do
  begin
    Memory.Write32(Address + 16 + Cardinal(I) * 4, At);
    Inc(At, BufferSize(Width, Height, I))
  end;
  Memory.Fill(Address + 128, Size - 128, 128);
end;

procedure WritePSPYCbCr(Memory: TPSPMemory; Address: Cardinal; const Frame: TVideoFrame);
begin
  if (PSPYCbCrSize(1, Frame.Width, Frame.Height) = 0) or not Memory.IsValid(Address, 48) then
    raise EPSPMemory.Create('PSP MPEG invalid YCbCr dimensions');
  if Memory.Read32(Address + 16) = 2 then
    raise EPlayerUnsupported.Create('PSP MPEG borrowed YCbCr buffers are not implemented');
  for var Plane := 0 to 2 do
  begin
    var Width := Frame.Width;
    var Height := Frame.Height;
    if Plane <> 0 then
    begin
      Width := Width div 2;
      Height := Height div 2
    end;
    if (Frame.Strides[Plane] < Width) or (Length(Frame.Planes[Plane]) < Frame.Strides[Plane] * Height) then
      raise EPlayerFormat.Create('PSP MPEG truncated YCbCr plane');
  end;
  for var Index := 0 to 7 do
  begin
    var Size := BufferSize(Frame.Width, Frame.Height, Index);
    var Destination := Memory.Read32(Address + 16 + Cardinal(Index) * 4);
    if not Memory.IsValid(Destination, Size) then
      raise EPSPMemory.Create('PSP MPEG invalid YCbCr plane range');
    var Data: TBytes;
    SetLength(Data, Size);
    var At := 0;
    var XStart := (Index and 1) * 16;
    var YStart := ((Index mod 4) div 2);
    if Index < 4 then
    begin
      var X := XStart;
      while X < Frame.Width do
      begin
        var Y := YStart;
        while Y < Frame.Height do
        begin
          Move(Frame.Planes[0][Y * Frame.Strides[0] + X], Data[At], 16);
          Inc(At, 16);
          Inc(Y, 2)
        end;
        Inc(X, 32);
      end;
    end
    else
    begin
      var X := XStart div 2;
      while X < Frame.Width div 2 do
      begin
        var Y := YStart;
        while Y < Frame.Height div 2 do
        begin
          for var K := 0 to 7 do
          begin
            Data[At] := Frame.Planes[1][Y * Frame.Strides[1] + X + K];
            Data[At + 1] := Frame.Planes[2][Y * Frame.Strides[2] + X + K];
            Inc(At, 2);
          end;
          Inc(Y, 2);
        end;
        Inc(X, 16);
      end;
    end;
    Memory.Load(Destination, Data);
  end;
  Memory.Write32(Address, Frame.Height div 16);
  Memory.Write32(Address + 4, Frame.Width div 16);
end;

function ReadPSPYCbCr(Memory: TPSPMemory; Address: Cardinal): TVideoFrame;
begin
  Result := Default(TVideoFrame);
  if not Memory.IsValid(Address, 48) then
    raise EPSPMemory.Create('PSP MPEG invalid YCbCr header');
  var MBWidth := Memory.Read32(Address + 4);
  var MBHeight := Memory.Read32(Address);
  if (MBWidth < 2) or (MBWidth > 30) or (MBHeight = 0) or (MBHeight > 17) then
    raise EPlayerFormat.Create('PSP MPEG invalid YCbCr macroblock dimensions');
  var Width := MBWidth * 16;
  var Height := MBHeight * 16;
  if PSPYCbCrSize(1, Width, Height) = 0 then
    raise EPlayerFormat.Create('PSP MPEG invalid YCbCr header dimensions');
  if Memory.Read32(Address + 16) = 2 then
    raise EPlayerUnsupported.Create('PSP MPEG borrowed YCbCr buffers are not implemented');
  Result.Width := Width;
  Result.Height := Height;
  for var Plane := 0 to 2 do
  begin
    var PW := Integer(Width);
    var PH := Integer(Height);
    if Plane <> 0 then
    begin
      PW := PW div 2;
      PH := PH div 2
    end;
    Result.Strides[Plane] := PW;
    SetLength(Result.Planes[Plane], PW * PH);
  end;
  for var Index := 0 to 7 do
  begin
    var Data := Memory.ReadBytes(Memory.Read32(Address + 16 + Cardinal(Index) * 4), BufferSize(Width, Height, Index));
    var At := 0;
    var XStart := (Index and 1) * 16;
    var YStart := (Index mod 4) div 2;
    if Index < 4 then
    begin
      var X := XStart;
      while X < Integer(Width) do
      begin
        var Y := YStart;
        while Y < Integer(Height) do
        begin
          Move(Data[At], Result.Planes[0][Y * Integer(Width) + X], 16);
          Inc(At, 16);
          Inc(Y, 2)
        end;
        Inc(X, 32);
      end;
    end
    else
    begin
      var X := XStart div 2;
      while X < Integer(Width) div 2 do
      begin
        var Y := YStart;
        while Y < Integer(Height) div 2 do
        begin
          for var K := 0 to 7 do
          begin
            Result.Planes[1][Y * Integer(Width div 2) + X + K] := Data[At];
            Result.Planes[2][Y * Integer(Width div 2) + X + K] := Data[At + 1];
            Inc(At, 2);
          end;
          Inc(Y, 2);
        end;
        Inc(X, 16);
      end;
    end;
  end;
end;

end.

