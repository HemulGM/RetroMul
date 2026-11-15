unit J2ME.Nokia.OTA;

interface

uses
  System.SysUtils;

type
  ENokiaToneFormat = class(Exception);

  TNokiaToneInstruction = record
    Kind, Value, Duration, Modifier: Integer;
  end;

  TNokiaTonePattern = record
    Repeats: Integer; // Additional repeats; 15 means forever.
    Instructions: TArray<TNokiaToneInstruction>;
  end;

  TNokiaToneSong = TArray<TNokiaTonePattern>;

function DecodeNokiaOTA(const Data: TBytes): TNokiaToneSong;

function NokiaTempo(Index: Integer): Integer;

implementation

type
  TBits = record
    Data: TBytes;
    Position: Integer;
    function Read(Count: Integer): Integer;
    procedure Align;
  end;

function TBits.Read(Count: Integer): Integer;
begin
  if (Count < 0) or (Count > 16) or (Int64(Position) + Count > Int64(Length(Data)) * 8) then
    raise ENokiaToneFormat.Create('Truncated Nokia OTA ringtone');
  Result := 0;
  for var I := 1 to Count do
  begin
    Result := (Result shl 1) or ((Data[Position div 8] shr (7 - Position mod 8)) and 1);
    Inc(Position);
  end;
end;

procedure TBits.Align;
begin
  while Position mod 8 <> 0 do
    if Read(1) <> 0 then
      raise ENokiaToneFormat.Create('Nonzero OTA padding');
end;

function NokiaTempo(Index: Integer): Integer;
const
  Values: array[0..31] of Integer = (25, 28, 31, 35, 40, 45, 50, 56, 63, 70, 80, 90, 100, 112, 125, 140,
    160, 180, 200, 225, 250, 285, 320, 355, 400, 450, 500, 565, 635, 715, 800, 900);
begin
  if (Index < 0) or (Index > 31) then
    raise ENokiaToneFormat.Create('OTA tempo');
  Result := Values[Index];
end;

function DecodeNokiaOTA(const Data: TBytes): TNokiaToneSong;
var
  Bits: TBits;
  Defined: array[0..3] of TArray<TNokiaToneInstruction>;
  Unicode, Programming, Found, Ended: Boolean;
  CommandCount, Command, SongType, ID, Count: Integer;
  Pattern: TNokiaTonePattern;
  Ins: TNokiaToneInstruction;

  procedure Need(Good: Boolean; const Why: string);
  begin
    if not Good then
      raise ENokiaToneFormat.Create(Why);
  end;

begin
  Result := nil;
  Bits.Data := Data;
  Bits.Position := 0;
  Unicode := False;
  Programming := False;
  Found := False;
  Ended := False;
  Need(Length(Data) <= 1024 * 1024, 'OTA encoded size limit');
  while Bits.Position < Int64(Length(Data)) * 8 do
  begin
    CommandCount := Bits.Read(8);
    if CommandCount = 0 then
    begin
      Ended := True;
      Break;
    end;
    for var Part := 1 to CommandCount do
    begin
      Command := Bits.Read(7);
      case Command of
        $25:
          begin
            Need(not Found, 'Unexpected OTA programming command');
            Programming := True;
          end;
        $22:
          begin
            Need(Programming and not Found, 'Unexpected OTA Unicode command');
            Unicode := True;
          end;
        $05:
          begin
            Need(Programming and not Found, 'Unexpected OTA cancel command');
            Need(Bits.Read(7) = $22, 'Unsupported OTA cancellation');
            Unicode := False;
          end;
        $1D:
          begin
            Need(Programming and not Found, 'Unexpected OTA sound command');
            Found := True;
            SongType := Bits.Read(3);
            Need((SongType = 1) or (SongType = 2), 'Unsupported OTA song type');
            if SongType = 1 then
            begin
              Count := Bits.Read(4);
              for var I := 1 to Count do
                if Unicode then
                  Bits.Read(16)
                else
                  Bits.Read(8);
            end;
            Count := Bits.Read(8);
            SetLength(Result, Count);
            for var P := 0 to Count - 1 do
            begin
              Need(Bits.Read(3) = 0, 'OTA pattern header');
              ID := Bits.Read(2);
              Pattern.Repeats := Bits.Read(4);
              var LengthOfPattern := Bits.Read(8);
              if LengthOfPattern = 0 then
              begin
                Need(Length(Defined[ID]) <> 0, 'Undefined OTA pattern');
                Pattern.Instructions := Defined[ID];
              end
              else
              begin
                Pattern.Instructions := nil;
                SetLength(Pattern.Instructions, LengthOfPattern);
                for var I := 0 to LengthOfPattern - 1 do
                begin
                  Ins := Default(TNokiaToneInstruction);
                  Ins.Kind := Bits.Read(3);
                  case Ins.Kind of
                    1:
                      begin
                        Ins.Value := Bits.Read(4);
                        Ins.Duration := Bits.Read(3);
                        Ins.Modifier := Bits.Read(2);
                        Need((Ins.Value <= 12) and (Ins.Duration <= 5), 'Reserved OTA note');
                      end;
                    2:
                      Ins.Value := Bits.Read(2);
                    3:
                      begin
                        Ins.Value := Bits.Read(2);
                        Need(Ins.Value <= 2, 'Reserved OTA style');
                      end;
                    4:
                      Ins.Value := Bits.Read(5);
                    5:
                      Ins.Value := Bits.Read(4);
                  else
                    raise ENokiaToneFormat.Create('Reserved OTA instruction');
                  end;
                  Pattern.Instructions[I] := Ins;
                end;
                Defined[ID] := Pattern.Instructions;
              end;
              if Pattern.Repeats = 15 then
              begin
                var Progress := False;
                for var I in Pattern.Instructions do
                  if I.Kind = 1 then
                    Progress := True;
                Need(Progress, 'Nonprogressing infinite OTA pattern');
              end;
              Result[P] := Pattern;
            end;
          end;
      else
        raise ENokiaToneFormat.Create('Unknown OTA command');
      end;
      Bits.Align;
    end;
  end;
  Need(Found and Ended, 'Incomplete OTA command stream');
  // Smart Messaging3.0 section3.6.1: command-end terminates the language.
  // Bytes in the enclosing buffer after that command are not OTA commands or
  // alignment padding. Validate padding inside command parts, not this suffix.
end;

end.

