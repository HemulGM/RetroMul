unit Core.RAR.GetBits;
{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}
// Free Pascal port of Unrar
// Unrar by Alexander Roshal
// Port by www.xelitan.com
// License: MIT
// The code cannot be used to recreate RAR compression

//  TBitInput — bit-level input buffer (getbits.hpp / getbits.cpp)

{$POINTERMATH ON}
{$Q-}{$R-}

interface

uses
  Core.RAR.Types;

type
  TBitInput = class
  public
    InAddr: Integer;   // current byte position in buffer
    InBit: Integer;   // current bit position within that byte
    ExternalBuffer: Boolean;
    InBuf: PByte;     // dynamically allocated or external

    constructor Create(AllocBuffer: Boolean);
    destructor Destroy; override;

    procedure InitBitInput; {$IFDEF FPC} inline;{$ENDIF}
    procedure addbits(Bits: LongWord); {$IFDEF FPC} inline;{$ENDIF}

    // Return 16 bits; bit at (InAddr,InBit) is the MSB of the result.
    function getbits: LongWord; {$IFDEF FPC} inline;{$ENDIF}

    // Return 32 bits (big-endian read).
    function getbits32: LongWord; {$IFDEF FPC} inline;{$ENDIF}

    // Return 64 bits (big-endian read).
    function getbits64: UInt64; {$IFDEF FPC} inline;{$ENDIF}

    // Function-wrapped versions used where code-size matters.
    procedure faddbits(Bits: LongWord);
    function fgetbits: LongWord;

    // True if buffer will overflow by IncPtr bytes.
    function Overflow(IncPtr: LongWord): Boolean; {$IFDEF FPC} inline;{$ENDIF}

    procedure SetExternalBuffer(Buf: PByte);
  end;

implementation

constructor TBitInput.Create(AllocBuffer: Boolean);
begin
  ExternalBuffer := False;
  if AllocBuffer then
  begin
    // getbits*() may read up to InAddr+8, so allocate 8 extra bytes.
    GetMem(InBuf, BITINPUT_MAX_SIZE + 8);
    FillChar(InBuf^, BITINPUT_MAX_SIZE + 8, 0);
  end
  else
    InBuf := nil;
end;

destructor TBitInput.Destroy;
begin
  if not ExternalBuffer then
    FreeMem(InBuf);
  inherited;
end;

procedure TBitInput.InitBitInput;
begin
  InAddr := 0;
  InBit := 0;
end;

procedure TBitInput.addbits(Bits: LongWord);
begin
  Inc(Bits, LongWord(InBit));
  Inc(InAddr, Integer(Bits shr 3));
  InBit := Integer(Bits and 7);
end;

function TBitInput.getbits: LongWord;
// Portable big-endian 16-bit read shifted by InBit.
var
  BitField: LongWord;
begin
  BitField := LongWord(InBuf[InAddr]) shl 16;
  BitField := BitField or (LongWord(InBuf[InAddr + 1]) shl 8);
  BitField := BitField or LongWord(InBuf[InAddr + 2]);
  Result := (BitField shr (8 - InBit)) and $FFFF;
end;

function TBitInput.getbits32: LongWord;
// Big-endian 32-bit read shifted by InBit.
var
  BitField: LongWord;
begin
  BitField := (LongWord(InBuf[InAddr]) shl 24)
    or (LongWord(InBuf[InAddr + 1]) shl 16)
    or (LongWord(InBuf[InAddr + 2]) shl 8)
    or LongWord(InBuf[InAddr + 3]);
  BitField := (BitField shl InBit)
    or (LongWord(InBuf[InAddr + 4]) shr (8 - InBit));
  Result := BitField;
end;

function TBitInput.getbits64: UInt64;
// Big-endian 64-bit read shifted by InBit.
var
  BitField: UInt64;
begin
  BitField := (UInt64(InBuf[InAddr]) shl 56)
    or (UInt64(InBuf[InAddr + 1]) shl 48)
    or (UInt64(InBuf[InAddr + 2]) shl 40)
    or (UInt64(InBuf[InAddr + 3]) shl 32)
    or (UInt64(InBuf[InAddr + 4]) shl 24)
    or (UInt64(InBuf[InAddr + 5]) shl 16)
    or (UInt64(InBuf[InAddr + 6]) shl 8)
    or UInt64(InBuf[InAddr + 7]);
  BitField := (BitField shl InBit)
    or (UInt64(InBuf[InAddr + 8]) shr (8 - InBit));
  Result := BitField;
end;

procedure TBitInput.faddbits(Bits: LongWord);
begin
  addbits(Bits);
end;

function TBitInput.fgetbits: LongWord;
begin
  Result := getbits;
end;

function TBitInput.Overflow(IncPtr: LongWord): Boolean;
begin
  Result := (LongWord(InAddr) + IncPtr) >= BITINPUT_MAX_SIZE;
end;

procedure TBitInput.SetExternalBuffer(Buf: PByte);
begin
  if (InBuf <> nil) and not ExternalBuffer then
    FreeMem(InBuf);
  InBuf := Buf;
  ExternalBuffer := True;
end;

end.

