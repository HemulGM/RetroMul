unit Java.Charsets;

interface

uses
  System.SysUtils, JVM.Runtime;

{$SCOPEDENUMS ON}

type
  TJavaCharset = (UTF8, Latin1, ASCII, UTF16, UTF16BE, UTF16LE);

type
  TJavaDecoder = record
    Charset: TJavaCharset;
    Started, Little: Boolean;
    procedure Init(Encoding: TJavaCharset);
  end;
// False means that no complete character is available yet. Position may still
// advance over an initial BOM; an incomplete character remains unconsumed.

function JavaDecodeNext(const Data: TBytes; var Position: Integer; Limit: Integer; var State: TJavaDecoder; EndOfInput: Boolean; out Codepoint: Integer): Boolean;

function JavaCharset(VM: TJVM; const Name: string): TJavaCharset;

function JavaEncode(VM: TJVM; const Text: string; Charset: TJavaCharset): TBytes;

function JavaDecode(VM: TJVM; const Data: TBytes; Charset: TJavaCharset): string;

implementation

{$Q-}{$R-}

function JavaCharset(VM: TJVM; const Name: string): TJavaCharset;
var
  N: string;
begin
  N := UpperCase(Name);
  if (N = 'UTF-8') or (N = 'UTF8') or (N = 'UNICODE-1-1-UTF-8') then
    Exit(TJavaCharset.UTF8);
  if (N = 'ISO-8859-1') or (N = 'ISO8859-1') or (N = 'ISO8859_1') or (N = 'ISO_8859_1') or
    (N = 'ISO_8859-1') or (N = 'ISO_8859-1:1987') or (N = 'LATIN1') or (N = 'L1') or
    (N = 'IBM819') or (N = 'CP819') or (N = '819') or (N = '8859_1') or (N = 'CSISOLATIN1') then
    Exit(TJavaCharset.Latin1);
  if (N = 'US-ASCII') or (N = 'ASCII') or (N = 'ISO646-US') or (N = 'ANSI_X3.4-1968') or
    (N = 'ANSI_X3.4-1986') or (N = 'ISO-IR-6') or (N = 'IBM367') or (N = 'CP367') or
    (N = 'CSASCII') or (N = 'ASCII7') or (N = 'US') then
    Exit(TJavaCharset.ASCII);
  if (N = 'UTF-16') or (N = 'UTF16') or (N = 'UNICODE') or (N = 'UNICODEBIG') then
    Exit(TJavaCharset.UTF16);
  if (N = 'UTF-16BE') or (N = 'X-UTF-16BE') or (N = 'UNICODEBIGUNMARKED') then
    Exit(TJavaCharset.UTF16BE);
  if (N = 'UTF-16LE') or (N = 'X-UTF-16LE') or (N = 'UNICODELITTLEUNMARKED') then
    Exit(TJavaCharset.UTF16LE);
  VM.RaiseJava('java/io/UnsupportedEncodingException', Name);
  Result := TJavaCharset.UTF8;
end;

function JavaEncode(VM: TJVM; const Text: string; Charset: TJavaCharset): TBytes;
var
  I, Count, Ch, Low: Integer;
  Total: Int64;

  procedure ByteValue(B: Integer);
  begin
    if Result <> nil then
      Result[Count] := Byte(B);
    Inc(Count);
  end;

  procedure WordValue(W: Integer);
  begin
    if Charset = TJavaCharset.UTF16LE then
    begin
      ByteValue(W);
      ByteValue(W shr 8);
    end
    else
    begin
      ByteValue(W shr 8);
      ByteValue(W);
    end;
  end;

  procedure Encode;
  begin
    Count := 0;
    I := 1;
    // UTF-16 emits its BOM for nonempty input. UTF-16BE/LE never emit one.
    if (Charset = TJavaCharset.UTF16) and (Text <> '') then
      WordValue($FEFF);
    while I <= Length(Text) do
    begin
      Ch := Ord(Text[I]);
      Inc(I);
      if (Ch >= $D800) and (Ch <= $DBFF) and (I <= Length(Text)) and
        (Ord(Text[I]) >= $DC00) and (Ord(Text[I]) <= $DFFF) then
      begin
        Low := Ord(Text[I]);
        Inc(I);
        if Charset in [TJavaCharset.UTF16, TJavaCharset.UTF16BE, TJavaCharset.UTF16LE] then
        begin
          WordValue(Ch);
          WordValue(Low);
          Continue;
        end;
        Ch := $10000 + ((Ch - $D800) shl 10) + Low - $DC00;
      end
      else if (Ch >= $D800) and (Ch <= $DFFF) then
      begin
        if Charset in [TJavaCharset.UTF16, TJavaCharset.UTF16BE, TJavaCharset.UTF16LE] then
          WordValue($FFFD)
        else
          ByteValue(63);
        Continue;
      end;
      case Charset of
        TJavaCharset.ASCII, TJavaCharset.Latin1:
          begin
            if (Ch > 255) or ((Charset = TJavaCharset.ASCII) and (Ch > 127)) then
              Ch := 63;
            ByteValue(Ch);
          end;
        TJavaCharset.UTF8:
          begin
            if Ch < $80 then
              ByteValue(Ch)
            else if Ch < $800 then
            begin
              ByteValue($C0 or (Ch shr 6));
              ByteValue($80 or (Ch and 63));
            end
            else
            begin
              if Ch > $FFFF then
              begin
                ByteValue($F0 or (Ch shr 18));
                ByteValue($80 or ((Ch shr 12) and 63));
              end
              else
                ByteValue($E0 or (Ch shr 12));
              ByteValue($80 or ((Ch shr 6) and 63));
              ByteValue($80 or (Ch and 63));
            end;
          end;
      else
        WordValue(Ch);
      end;
    end;
  end;

begin
  Result := nil;
  // A separate size pass bounds allocation and avoids RTL-specific replacement
  // rules, platform code pages and automatic BOM insertion.
  Total := Int64(Length(Text)) * 3 + 2;
  if Total > MaxInt then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Encoded text size');
  Encode;
  if Count > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Encoded text limit');
  if Count = 0 then
    Exit;
  SetLength(Result, Count);
  Encode;
end;

procedure TJavaDecoder.Init(Encoding: TJavaCharset);
begin
  Charset := Encoding;
  Started := False;
  Little := Encoding = TJavaCharset.UTF16LE;
end;

function JavaDecodeNext(const Data: TBytes; var Position: Integer; Limit: Integer; var State: TJavaDecoder; EndOfInput: Boolean; out Codepoint: Integer): Boolean;

  function WordValue(Index: Integer): Integer;
  begin
    if State.Little then
      Result := Data[Index] or (Integer(Data[Index + 1]) shl 8)
    else
      Result := (Integer(Data[Index]) shl 8) or Data[Index + 1];
  end;

  function Continuation(Index: Integer): Boolean;
  begin
    Result := (Index < Limit) and ((Data[Index] and $C0) = $80);
  end;

begin
  Result := False;
  Codepoint := -1;
  if not State.Started then
  begin
    if State.Charset = TJavaCharset.UTF16 then
    begin
      if Limit - Position < 2 then
      begin
        if not EndOfInput then
          Exit;
      end
      else if (Data[Position] = $FE) and (Data[Position + 1] = $FF) then
        Inc(Position, 2)
      else if (Data[Position] = $FF) and (Data[Position + 1] = $FE) then
      begin
        State.Little := True;
        Inc(Position, 2);
      end;
    end;
    State.Started := True;
  end;
  if Position >= Limit then
    Exit;
  if State.Charset in [TJavaCharset.ASCII, TJavaCharset.Latin1] then
  begin
    Codepoint := Data[Position];
    Inc(Position);
    if (State.Charset = TJavaCharset.ASCII) and (Codepoint > 127) then
      Codepoint := $FFFD;
    Exit(True);
  end;
  if State.Charset in [TJavaCharset.UTF16, TJavaCharset.UTF16BE, TJavaCharset.UTF16LE] then
  begin
    if Limit - Position < 2 then
    begin
      if not EndOfInput then
        Exit;
      Position := Limit;
      Codepoint := $FFFD;
      Exit(True);
    end;
    var Ch := WordValue(Position);
    if (Ch >= $D800) and (Ch <= $DBFF) then
    begin
      if Limit - Position < 4 then
      begin
        if not EndOfInput then
          Exit;
        Position := Limit;
        Codepoint := $FFFD;
        Exit(True);
      end;
      var Low := WordValue(Position + 2);
      Inc(Position, 4);
      if (Low >= $DC00) and (Low <= $DFFF) then
        Codepoint := $10000 + ((Ch - $D800) shl 10) + Low - $DC00
      else
        Codepoint := $FFFD;
    end
    else
    begin
      Inc(Position, 2);
      if (Ch >= $DC00) and (Ch <= $DFFF) then
        Codepoint := $FFFD
      else
        Codepoint := Ch;
    end;
    Exit(True);
  end;
  var B := Integer(Data[Position]);
  Codepoint := B;
  var Needed := 1;
  if B >= $80 then
  begin
    Codepoint := $FFFD;
    if (B >= $C2) and (B <= $DF) then
      Needed := 2
    else if (B >= $E0) and (B <= $EF) then
      Needed := 3
    else if (B >= $F0) and (B <= $F4) then
      Needed := 4;
  end;
  var Used := 1;
  if Needed > 1 then
  begin
    var Next := Position + 1;
    if Next = Limit then
    begin
      if not EndOfInput then
        Exit;
    end
    else if Continuation(Next) and not (((B = $E0) and (Data[Next] < $A0)) or
      ((B = $F0) and (Data[Next] < $90)) or ((B = $F4) and (Data[Next] > $8F))) then
    begin
      Used := 2;
      while (Used < Needed) and Continuation(Position + Used) do
        Inc(Used);
      if Used < Needed then
      begin
        if (Position + Used = Limit) and not EndOfInput then
          Exit;
      end
      else
      begin
        case Needed of
          2:
            Codepoint := ((B and $1F) shl 6) or (Data[Position + 1] and 63);
          3:
            Codepoint := ((B and 15) shl 12) or ((Data[Position + 1] and 63) shl 6) or (Data[Position + 2] and 63);
          4:
            Codepoint := ((B and 7) shl 18) or ((Data[Position + 1] and 63) shl 12) or ((Data[Position + 2] and 63) shl 6) or (Data[Position + 3] and 63);
        end;
        if (Codepoint >= $D800) and (Codepoint <= $DFFF) then
          Codepoint := $FFFD;
      end;
    end;
  end;
  Inc(Position, Used);
  Result := True;
end;

function JavaDecode(VM: TJVM; const Data: TBytes; Charset: TJavaCharset): string;
var
  State: TJavaDecoder;
  Position, Count, Codepoint: Integer;
begin
  if Length(Data) > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Decoded text limit');
  SetLength(Result, Length(Data));
  State.Init(Charset);
  Position := 0;
  Count := 0;
  while JavaDecodeNext(Data, Position, Length(Data), State, True, Codepoint) do
  begin
    if Codepoint > $FFFF then
    begin
      Dec(Codepoint, $10000);
      Inc(Count);
      Result[Count] := Char($D800 or (Codepoint shr 10));
      Codepoint := $DC00 or (Codepoint and $3FF);
    end;
    Inc(Count);
    Result[Count] := Char(Codepoint);
  end;
  SetLength(Result, Count);
end;

end.

