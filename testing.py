import sys
import math

def analyze(filename):
    with open(filename, 'r') as f:
        numbers = []
        for line in f:
            line = line.strip()
            if line and all(c in '0123456789abcdefABCDEF' for c in line):
                numbers.append(int(line, 16))
    
    if not numbers:
        print("No data!")
        return
    
    print("=" * 50)
    print("  PRNG Quality Analysis (with Avalanche Hash)")
    print("=" * 50)
    print(f"\nNumbers: {len(numbers)}")
    
    # Все числа
    print("\nAll numbers:")
    for i, v in enumerate(numbers):
        print(f"  {i+1}: 0x{v:08X}")
    
    # 1. Bit balance
    all_bits = []
    for v in numbers:
        for b in range(32):
            all_bits.append((v >> b) & 1)
    
    ones = sum(all_bits)
    total = len(all_bits)
    ratio = ones / total
    passed = 0.45 < ratio < 0.55
    print(f"\n1. Bit balance: {ones}/{total} = {100*ratio:.1f}%")
    print(f"   {'PASS' if passed else 'FAIL'}")
    
    # 2. Uniqueness
    unique = len(set(numbers))
    print(f"\n2. Uniqueness: {unique}/{len(numbers)}")
    print(f"   {'PASS' if unique == len(numbers) else 'FAIL'}")
    
    # 3. Runs test
    runs = 1
    for i in range(1, len(all_bits)):
        if all_bits[i] != all_bits[i-1]:
            runs += 1
    n0 = total - ones
    n1 = ones
    if n0 > 0 and n1 > 0:
        expected = 2 * n0 * n1 / total + 1
        std = math.sqrt(2 * n0 * n1 * (2*n0*n1 - total) / (total**2 * (total-1)))
        z = abs(runs - expected) / std if std > 0 else 0
        runs_pass = z < 2.576  # 99% confidence
        print(f"\n3. Runs test:")
        print(f"   Runs: {runs}, Expected: {expected:.0f}")
        print(f"   Z-score: {z:.2f}")
        print(f"   {'PASS' if runs_pass else 'FAIL'}")
    
    # 4. Byte distribution
    all_bytes = []
    for v in numbers:
        for i in range(4):
            all_bytes.append((v >> (i*8)) & 0xFF)
    unique_bytes = len(set(all_bytes))
    print(f"\n4. Byte distribution:")
    print(f"   Total: {len(all_bytes)}, Unique: {unique_bytes}")
    
    # 5. Autocorrelation
    if len(all_bits) > 10:
        mean = sum(all_bits) / len(all_bits)
        num = sum((all_bits[i]-mean)*(all_bits[i+1]-mean) 
                  for i in range(len(all_bits)-1))
        den = sum((b-mean)**2 for b in all_bits)
        ac = num / den if den > 0 else 0
        ac_pass = abs(ac) < 0.05
        print(f"\n5. Autocorrelation (lag=1): {ac:.4f}")
        print(f"   {'PASS' if ac_pass else 'WARNING'}")
    
    # 6. Bit position balance (avalanche check)
    print(f"\n6. Per-bit balance (avalanche quality):")
    bit_ones = [0] * 32
    for v in numbers:
        for b in range(32):
            bit_ones[b] += (v >> b) & 1
    
    worst_bit = -1
    worst_ratio = 0.5
    for b in range(32):
        r = bit_ones[b] / len(numbers)
        if abs(r - 0.5) > abs(worst_ratio - 0.5):
            worst_ratio = r
            worst_bit = b
    
    print(f"   Worst bit: [{worst_bit}] = {100*worst_ratio:.0f}%")
    print(f"   {'PASS' if 0.2 < worst_ratio < 0.8 else 'FAIL'}")
    
    # 7. Hamming distance between consecutive numbers
    if len(numbers) > 1:
        distances = []
        for i in range(len(numbers)-1):
            xor = numbers[i] ^ numbers[i+1]
            distances.append(bin(xor).count('1'))
        avg_dist = sum(distances) / len(distances)
        print(f"\n7. Hamming distance (consecutive):")
        print(f"   Average: {avg_dist:.1f} / 32")
        print(f"   Expected: ~16")
        print(f"   {'PASS' if 12 < avg_dist < 20 else 'FAIL'}")
    
    print("\n" + "=" * 50)

if __name__ == "__main__":
    fn = sys.argv[1] if len(sys.argv) > 1 else "random_output.txt"
    analyze(fn)