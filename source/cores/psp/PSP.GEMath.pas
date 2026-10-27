unit PSP.GEMath;

{$Q-}{$R-}

// Native port of PPSSPP GPU/Software/GEMath.h/.cpp, GPL-2.0-or-later.
// Copyright (c) 2012- PPSSPP Project. Measured PSP GE float24 arithmetic.
// Reference commit: 68c85fd6942e18dc5f44c1c67268500c0646aaea.

interface

type
  TPSPGEMatrix = array[0..15] of Single;
  TPSPGEClip = array[0..3] of Single;

const
  ReciprocalSegments:array[0..127] of record Base,Slope:Integer end=(
    (Base:131072;Slope:-254),
    (Base:130055;Slope:-250),
    (Base:129054;Slope:-246),
    (Base:128071;Slope:-243),
    (Base:127099;Slope:-239),
    (Base:126143;Slope:-235),
    (Base:125203;Slope:-232),
    (Base:124274;Slope:-228),
    (Base:123361;Slope:-225),
    (Base:122461;Slope:-222),
    (Base:121574;Slope:-219),
    (Base:120700;Slope:-216),
    (Base:119836;Slope:-212),
    (Base:118986;Slope:-209),
    (Base:118150;Slope:-207),
    (Base:117323;Slope:-204),
    (Base:116508;Slope:-201),
    (Base:115704;Slope:-198),
    (Base:114913;Slope:-196),
    (Base:114130;Slope:-193),
    (Base:113358;Slope:-190),
    (Base:112599;Slope:-188),
    (Base:111847;Slope:-185),
    (Base:111107;Slope:-183),
    (Base:110375;Slope:-180),
    (Base:109654;Slope:-178),
    (Base:108943;Slope:-176),
    (Base:108239;Slope:-173),
    (Base:107545;Slope:-171),
    (Base:106861;Slope:-169),
    (Base:106184;Slope:-167),
    (Base:105517;Slope:-165),
    (Base:104858;Slope:-163),
    (Base:104206;Slope:-161),
    (Base:103563;Slope:-159),
    (Base:102927;Slope:-157),
    (Base:102300;Slope:-155),
    (Base:101680;Slope:-153),
    (Base:101067;Slope:-151),
    (Base:100463;Slope:-150),
    (Base:99865;Slope:-148),
    (Base:99273;Slope:-146),
    (Base:98689;Slope:-144),
    (Base:98113;Slope:-143),
    (Base:97542;Slope:-141),
    (Base:96977;Slope:-139),
    (Base:96421;Slope:-138),
    (Base:95869;Slope:-136),
    (Base:95326;Slope:-135),
    (Base:94786;Slope:-133),
    (Base:94255;Slope:-132),
    (Base:93727;Slope:-130),
    (Base:93207;Slope:-129),
    (Base:92691;Slope:-127),
    (Base:92182;Slope:-126),
    (Base:91680;Slope:-125),
    (Base:91180;Slope:-123),
    (Base:90688;Slope:-122),
    (Base:90201;Slope:-121),
    (Base:89717;Slope:-119),
    (Base:89240;Slope:-118),
    (Base:88769;Slope:-117),
    (Base:88302;Slope:-116),
    (Base:87838;Slope:-114),
    (Base:87381;Slope:-113),
    (Base:86928;Slope:-112),
    (Base:86481;Slope:-111),
    (Base:86037;Slope:-110),
    (Base:85599;Slope:-109),
    (Base:85164;Slope:-108),
    (Base:84732;Slope:-106),
    (Base:84307;Slope:-105),
    (Base:83885;Slope:-104),
    (Base:83468;Slope:-103),
    (Base:83055;Slope:-102),
    (Base:82646;Slope:-101),
    (Base:82241;Slope:-100),
    (Base:81839;Slope:-99),
    (Base:81442;Slope:-98),
    (Base:81049;Slope:-97),
    (Base:80659;Slope:-96),
    (Base:80275;Slope:-96),
    (Base:79892;Slope:-95),
    (Base:79513;Slope:-94),
    (Base:79138;Slope:-93),
    (Base:78766;Slope:-92),
    (Base:78398;Slope:-91),
    (Base:78033;Slope:-90),
    (Base:77673;Slope:-90),
    (Base:77315;Slope:-89),
    (Base:76960;Slope:-88),
    (Base:76608;Slope:-87),
    (Base:76260;Slope:-86),
    (Base:75914;Slope:-85),
    (Base:75574;Slope:-85),
    (Base:75234;Slope:-84),
    (Base:74898;Slope:-83),
    (Base:74564;Slope:-82),
    (Base:74236;Slope:-82),
    (Base:73908;Slope:-81),
    (Base:73584;Slope:-80),
    (Base:73264;Slope:-80),
    (Base:72944;Slope:-79),
    (Base:72628;Slope:-78),
    (Base:72316;Slope:-78),
    (Base:72005;Slope:-77),
    (Base:71697;Slope:-76),
    (Base:71393;Slope:-76),
    (Base:71090;Slope:-75),
    (Base:70789;Slope:-74),
    (Base:70493;Slope:-74),
    (Base:70197;Slope:-73),
    (Base:69906;Slope:-73),
    (Base:69615;Slope:-72),
    (Base:69327;Slope:-71),
    (Base:69042;Slope:-71),
    (Base:68759;Slope:-70),
    (Base:68479;Slope:-70),
    (Base:68200;Slope:-69),
    (Base:67925;Slope:-69),
    (Base:67650;Slope:-68),
    (Base:67378;Slope:-67),
    (Base:67109;Slope:-67),
    (Base:66841;Slope:-66),
    (Base:66577;Slope:-66),
    (Base:66313;Slope:-65),
    (Base:66052;Slope:-65),
    (Base:65793;Slope:-64));

function GETruncate(Value: Single): Single; inline;
function GEProduct(Value: Double): Single; inline;
function GEUVProduct(Value: Double): Single; inline;
function GEAdd(A,B: Single): Single;
function GEReciprocal(W: Single): Single; inline;
function GEScalePower2(Value: Single; Power: Integer): Single;
function GEViewport(Coordinate,W,Scale,Center: Single): Single;
function GETransform(const Position: TPSPGEClip; const Matrix: TPSPGEMatrix): TPSPGEClip;
procedure GECombine(out Destination: TPSPGEMatrix; const A,B: TPSPGEMatrix);

implementation

uses System.Math;

type
  TGERowTerm = record
    Mantissa, Exponent: Integer;
  end;
  TGERow = array[0..3] of TGERowTerm;

function GETruncate(Value: Single): Single;
begin
  var Bits:Cardinal;Move(Value,Bits,4);Bits:=Bits and $FFFFFF00;Move(Bits,Result,4);
end;

function GEProduct(Value: Double): Single;
begin
  var Bits:UInt64;Move(Value,Bits,8);
  if Bits and $7FF0000000000000<>$7FF0000000000000 then Bits:=Bits and $FFFFFFE000000000;
  Move(Bits,Value,8);Result:=Single(Value);
end;

function GEUVProduct(Value: Double): Single;
begin
  var Bits:UInt64;Move(Value,Bits,8);
  if Bits and $7FF0000000000000<>$7FF0000000000000 then Bits:=Bits and $FFFFFFFFE0000000;
  Move(Bits,Value,8);Result:=Single(Value);
end;

function GEAdd(A,B: Single): Single;
begin
  var BA,BB:Cardinal;Move(A,BA,4);Move(B,BB,4);
  var EA:=Integer((BA shr 23) and 255);var EB:=Integer((BB shr 23) and 255);
  if (EA=0) or (EB=0) then
  begin
    if EA<>0 then Exit(GETruncate(A));
    if EB<>0 then Exit(GETruncate(B));
    Exit(0);
  end;
  var EMax:=Max(EA,EB);var NA:=8+EMax-EA;var NB:=8+EMax-EB;
  if NA>=24 then BA:=BA and $80000000 else BA:=BA and not ((Cardinal(1) shl NA)-1);
  if NB>=24 then BB:=BB and $80000000 else BB:=BB and not ((Cardinal(1) shl NB)-1);
  Move(BA,A,4);Move(BB,B,4);Result:=A+B;
end;

function GEScalePower2(Value: Single; Power: Integer): Single;
begin
  var Bits:Cardinal;Move(Value,Bits,4);var Field:=Integer((Bits shr 23) and 255);
  if (Field=0) or (Field=255) or (Field+Power<1) or (Field+Power>254) then
    Exit(Single(Ldexp(Value,Power)));
  Inc(Bits,Cardinal(Power) shl 23);Move(Bits,Result,4);
end;

function GEReciprocal(W: Single): Single;
begin
  var Bits:Cardinal;Move(W,Bits,4);
  var Index:=(Bits shr 8) and $7FFF;
  var E:=Integer((Bits shr 23) and 255)-127;
  var Segment:=ReciprocalSegments[Index shr 8];
  var Q:=(64*Segment.Base+63+Segment.Slope*Integer(Index and 255)) shr 7;
  if E>=126 then
  begin
    Result:=GEScalePower2(Single(Q),-16-E);
    Move(Result,Index,4);
  end
  else
  begin
    // Q has at most 17 significant bits. In the normal case scaling is an
    // exponent-field addition, without a second function call or FP rounding.
    var Quotient:Single:=Q;Move(Quotient,Index,4);
    Inc(Index,Cardinal(-16-E) shl 23);
  end;
  Index:=Index or (Bits and $80000000);Move(Index,Result,4);
end;

function RowProduct(A,B: Single): TGERowTerm;
begin
  var BA,BB:Cardinal;Move(A,BA,4);Move(B,BB,4);
  var EA:=Integer((BA shr 23) and 255);var EB:=Integer((BB shr 23) and 255);
  if (EA=0) or (EB=0) then begin Result.Mantissa:=0;Result.Exponent:=Low(Integer);Exit end;
  var MA:=UInt64((BA and $7FFFFF) or $800000);var MB:=UInt64((BB and $7FFFFF) or $800000);
  Result.Mantissa:=Integer((MA*MB) shr 31);
  if (BA xor BB) and $80000000<>0 then Result.Mantissa:=-Result.Mantissa;
  Result.Exponent:=EA+EB-254-15;
end;

function RowSum(const Terms: TGERow): Single;
begin
  var E:=Low(Integer);
  for var Term in Terms do E:=Max(E,Term.Exponent);
  var Sum:=0;
  for var Term in Terms do
    if Term.Mantissa<>0 then
    begin
      var Shift:=E-Term.Exponent;
      if Shift<32 then
        if Term.Mantissa<0 then Dec(Sum,Integer(Cardinal(-Term.Mantissa) shr Shift))
        else Inc(Sum,Integer(Cardinal(Term.Mantissa) shr Shift));
    end;
  if Sum=0 then Exit(0);
  Result:=GETruncate(GEScalePower2(Single(Sum),E));
end;

function GETransform(const Position: TPSPGEClip; const Matrix: TPSPGEMatrix): TPSPGEClip;
begin
  var Terms:TGERow;
  for var C:=0 to 3 do
  begin
    for var K:=0 to 3 do Terms[K]:=RowProduct(GETruncate(Position[K]),Matrix[K*4+C]);
    Result[C]:=RowSum(Terms);
  end;
end;

procedure GECombine(out Destination: TPSPGEMatrix; const A,B: TPSPGEMatrix);
begin
  var Terms:TGERow;var Product:TPSPGEMatrix;
  for var R:=0 to 3 do for var C:=0 to 3 do
  begin
    for var K:=0 to 3 do Terms[K]:=RowProduct(A[R*4+K],B[K*4+C]);
    Product[R*4+C]:=RowSum(Terms);
  end;
  Destination:=Product;
end;

function GEViewport(Coordinate,W,Scale,Center: Single): Single;
begin
  var W24:Single:=GETruncate(W);var Bits:Cardinal;Move(W24,Bits,4);
  var CBits:Cardinal;Move(Coordinate,CBits,4);
  if (Bits and $7F800000=0) or (Bits and $7F800000=$7F800000) or
    (CBits and $7F800000=$7F800000) then
  begin
    // The caller rejects the non-finite projection. Do not divide by zero on
    // Delphi hosts where a guest's degenerate vertex would raise a host fault.
    if Bits and $7FFFFFFF=0 then begin Bits:=$7FC00000;Move(Bits,Result,4);Exit end;
    Exit(Coordinate*Scale/W+Center);
  end;
  var NDC:Single:=GEProduct(Double(GETruncate(Coordinate))*GEReciprocal(W24));
  Result:=GEAdd(GEProduct(Double(NDC)*Scale),Center);
end;

end.
