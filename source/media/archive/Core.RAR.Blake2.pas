unit Core.RAR.Blake2;

interface

uses
  System.SysUtils;

type
  // BLAKE2sp-256: eight interleaved BLAKE2s leaves and one root.
  TRarBlake2sp = class
  private
    type
      TState = record
        H: array[0..7] of Cardinal;
        Buffer: array[0..63] of Byte;
        Used: Integer;
        Count: UInt64;
        LastNode: Boolean;
      end;
  private
    FLeaves: array[0..7] of TState;
    FBlock: array[0..63] of Byte;
    FUsed, FLeaf: Integer;
    class procedure Init(var S: TState; Node, Depth: Cardinal; Last: Boolean); static;
    class procedure Compress(var S: TState; FinalBlock: Boolean); static;
    class procedure Feed(var S: TState; Data: PByte; Size: Integer); static;
    class function Finish(var S: TState): TBytes; static;
  public
    constructor Create;
    procedure Update(Data: PByte; Size: NativeUInt);
    function Digest: TBytes;
  end;

implementation

{$Q-}{$R-}{$POINTERMATH ON}

const
  IV: array[0..7] of Cardinal = ($6A09E667, $BB67AE85, $3C6EF372, $A54FF53A,
    $510E527F, $9B05688C, $1F83D9AB, $5BE0CD19);
  Sigma: array[0..9, 0..15] of Byte = (
    (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15),
    (14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3),
    (11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4),
    (7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8),
    (9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13),
    (2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9),
    (12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11),
    (13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10),
    (6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5),
    (10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0));

function Ror32(X: Cardinal; N: Integer): Cardinal; inline;
begin
  Result := (X shr N) or (X shl (32 - N));
end;

class procedure TRarBlake2sp.Init(var S: TState; Node, Depth: Cardinal; Last: Boolean);
begin
  FillChar(S, SizeOf(S), 0);
  for var I := 0 to 7 do
    S.H[I] := IV[I];
  S.H[0] := S.H[0] xor $02080020;
  S.H[2] := S.H[2] xor Node;
  S.H[3] := S.H[3] xor $20000000 xor (Depth shl 16);
  S.LastNode := Last;
end;

class procedure TRarBlake2sp.Compress(var S: TState; FinalBlock: Boolean);
var
  V, M: array[0..15] of Cardinal;

  procedure G(A, B, C, D: Integer; X, Y: Cardinal);
  begin
    V[A] := V[A] + V[B] + X;
    V[D] := Ror32(V[D] xor V[A], 16);
    V[C] := V[C] + V[D];
    V[B] := Ror32(V[B] xor V[C], 12);
    V[A] := V[A] + V[B] + Y;
    V[D] := Ror32(V[D] xor V[A], 8);
    V[C] := V[C] + V[D];
    V[B] := Ror32(V[B] xor V[C], 7);
  end;

begin
  for var I := 0 to 15 do
    M[I] := Cardinal(S.Buffer[I * 4]) or (Cardinal(S.Buffer[I * 4 + 1]) shl 8) or
      (Cardinal(S.Buffer[I * 4 + 2]) shl 16) or (Cardinal(S.Buffer[I * 4 + 3]) shl 24);
  for var I := 0 to 7 do
  begin
    V[I] := S.H[I];
    V[I + 8] := IV[I];
  end;
  V[12] := V[12] xor Cardinal(S.Count);
  V[13] := V[13] xor Cardinal(S.Count shr 32);
  if FinalBlock then
  begin
    V[14] := not V[14];
    if S.LastNode then
      V[15] := not V[15];
  end;
  for var R := 0 to 9 do
  begin
    G(0, 4, 8, 12, M[Sigma[R, 0]], M[Sigma[R, 1]]);
    G(1, 5, 9, 13, M[Sigma[R, 2]], M[Sigma[R, 3]]);
    G(2, 6, 10, 14, M[Sigma[R, 4]], M[Sigma[R, 5]]);
    G(3, 7, 11, 15, M[Sigma[R, 6]], M[Sigma[R, 7]]);
    G(0, 5, 10, 15, M[Sigma[R, 8]], M[Sigma[R, 9]]);
    G(1, 6, 11, 12, M[Sigma[R, 10]], M[Sigma[R, 11]]);
    G(2, 7, 8, 13, M[Sigma[R, 12]], M[Sigma[R, 13]]);
    G(3, 4, 9, 14, M[Sigma[R, 14]], M[Sigma[R, 15]]);
  end;
  for var I := 0 to 7 do
    S.H[I] := S.H[I] xor V[I] xor V[I + 8];
end;

class procedure TRarBlake2sp.Feed(var S: TState; Data: PByte; Size: Integer);
begin
  while Size > 0 do
  begin
    if S.Used = 64 then
    begin
      Inc(S.Count, 64);
      Compress(S, False);
      S.Used := 0;
    end;
    var N := 64 - S.Used;
    if N > Size then
      N := Size;
    Move(Data^, S.Buffer[S.Used], N);
    Inc(Data, N);
    Inc(S.Used, N);
    Dec(Size, N);
  end;
end;

class function TRarBlake2sp.Finish(var S: TState): TBytes;
begin
  Inc(S.Count, UInt64(S.Used));
  if S.Used < 64 then
    FillChar(S.Buffer[S.Used], 64 - S.Used, 0);
  Compress(S, True);
  SetLength(Result, 32);
  for var I := 0 to 31 do
    Result[I] := Byte(S.H[I div 4] shr ((I mod 4) * 8));
end;

constructor TRarBlake2sp.Create;
begin
  inherited;
  for var I := 0 to 7 do
    Init(FLeaves[I], I, 0, I = 7);
end;

procedure TRarBlake2sp.Update(Data: PByte; Size: NativeUInt);
begin
  while Size > 0 do
  begin
    var N := 64 - FUsed;
    if NativeUInt(N) > Size then
      N := Size;
    Move(Data^, FBlock[FUsed], N);
    Inc(Data, N);
    Inc(FUsed, N);
    Dec(Size, N);
    if FUsed = 64 then
    begin
      Feed(FLeaves[FLeaf], @FBlock[0], 64);
      FLeaf := (FLeaf + 1) and 7;
      FUsed := 0;
    end;
  end;
end;

function TRarBlake2sp.Digest: TBytes;
begin
  if FUsed > 0 then
    Feed(FLeaves[FLeaf], @FBlock[0], FUsed);
  var Root: TState;
  Init(Root, 0, 1, True);
  for var I := 0 to 7 do
  begin
    var Bytes := Finish(FLeaves[I]);
    Feed(Root, @Bytes[0], Length(Bytes));
  end;
  Result := Finish(Root);
end;

end.

