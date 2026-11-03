// Double precision division exactly as SSE2 divsd does it (round to nearest
// even, denormals kept, x86 NaN rules), by long division of the significands:
// the devices' own double division is not correctly rounded.

double bitsToDouble(uint64_t v)
{
  return packDouble2x32(unpackUint2x32(v));
}

uint64_t doubleToBits(double v)
{
  return packUint2x32(unpackDouble2x32(v));
}

double divD(double a, double b)
{
  const uint64_t SignBit = 0x8000000000000000ul;
  const uint64_t FracMask = 0x000FFFFFFFFFFFFFul;
  const uint64_t Hidden = 0x0010000000000000ul;
  const uint64_t Quiet = 0x0008000000000000ul;
  const uint64_t Inf = 0x7FF0000000000000ul;
  const uint64_t Indefinite = 0xFFF8000000000000ul;
  uint64_t ua = doubleToBits(a);
  uint64_t ub = doubleToBits(b);
  uint64_t sign = (ua ^ ub) & SignBit;
  int ea = int((ua >> 52) & 0x7FFul);
  int eb = int((ub >> 52) & 0x7FFul);
  uint64_t ma = ua & FracMask;
  uint64_t mb = ub & FracMask;
  if (ea == 0x7FF && ma != 0ul)
    return bitsToDouble(ua | Quiet);
  if (eb == 0x7FF && mb != 0ul)
    return bitsToDouble(ub | Quiet);
  if (ea == 0x7FF)
    return bitsToDouble(eb == 0x7FF ? Indefinite : (sign | Inf));
  if (eb == 0x7FF)
    return bitsToDouble(sign);
  bool zeroA = ea == 0 && ma == 0ul;
  bool zeroB = eb == 0 && mb == 0ul;
  if (zeroB)
    return bitsToDouble(zeroA ? Indefinite : (sign | Inf));
  if (zeroA)
    return bitsToDouble(sign);
  if (ea == 0)
  {
    ea = 1;
    while ((ma & Hidden) == 0ul)
    {
      ma <<= 1;
      ea--;
    }
  }
  else
    ma |= Hidden;
  if (eb == 0)
  {
    eb = 1;
    while ((mb & Hidden) == 0ul)
    {
      mb <<= 1;
      eb--;
    }
  }
  else
    mb |= Hidden;
  int e = ea - eb + 1023;
  uint64_t r = ma;
  if (r < mb)
  {
    r <<= 1;
    e--;
  }
  // 54 quotient bits: the leading one, 52 fraction bits and the round bit.
  uint64_t q = 0ul;
  for (int i = 0; i < 54; i++)
  {
    q <<= 1;
    if (r >= mb)
    {
      r -= mb;
      q |= 1ul;
    }
    r <<= 1;
  }
  bool sticky = r != 0ul;
  int shift = 1;
  if (e <= 0)
  {
    shift = 2 - e;
    e = 0;
  }
  uint64_t mant;
  bool roundBit;
  if (shift >= 64)
  {
    mant = 0ul;
    roundBit = false;
    sticky = true;
  }
  else
  {
    mant = q >> uint(shift);
    roundBit = ((q >> uint(shift - 1)) & 1ul) != 0ul;
    if (shift >= 2 && (q & ((1ul << uint(shift - 1)) - 1ul)) != 0ul)
      sticky = true;
  }
  if (roundBit && (sticky || (mant & 1ul) != 0ul))
    mant++;
  if (e == 0)
    return bitsToDouble(sign | mant);
  if (mant == (Hidden << 1))
  {
    mant >>= 1;
    e++;
  }
  if (e >= 0x7FF)
    return bitsToDouble(sign | Inf);
  return bitsToDouble(sign | (uint64_t(e) << 52) | (mant & FracMask));
}
