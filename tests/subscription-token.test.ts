import { describe, it, expect, beforeEach } from "vitest";

interface Subscription {
  tier: bigint;
  startBlock: bigint;
  duration: bigint;
  autoRenew: boolean;
  active: boolean;
}

interface MockContract {
  admin: string;
  minter: string;
  paused: boolean;
  balances: Map<string, bigint>;
  allowances: Map<string, bigint>;
  subscriptions: Map<string, Subscription>;
  blockHeight: bigint;
  TIER_BASIC: bigint;
  TIER_PRO: bigint;
  TIER_ENTERPRISE: bigint;
  tierDurations: Map<bigint, bigint>;

  isAdmin(caller: string): boolean;
  isMinter(caller: string): boolean;
  setPaused(caller: string, pause: boolean): { value: boolean } | { error: number };
  setMinter(caller: string, newMinter: string): { value: boolean } | { error: number };
  subscribeMint(caller: string, recipient: string, tier: bigint, amount: bigint, autoRenew: boolean): { value: boolean } | { error: number };
  transfer(caller: string, amount: bigint, sender: string, recipient: string): { value: boolean } | { error: number };
  approve(caller: string, spender: string, amount: bigint): { value: boolean } | { error: number };
  cancelBurn(caller: string): { value: bigint } | { error: number };
  renew(caller: string, user: string): { value: boolean } | { error: number };
  toggleAutoRenew(caller: string, enable: boolean): { value: boolean } | { error: number };
  emergencyBurn(caller: string, user: string, amount: bigint): { value: boolean } | { error: number };
  getBalance(user: string): bigint;
  isActive(user: string): boolean;
}

const mockContract: MockContract = {
  admin: "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM",
  minter: "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM",
  paused: false,
  balances: new Map<string, bigint>(),
  allowances: new Map<string, bigint>(),
  subscriptions: new Map<string, Subscription>(),
  blockHeight: 10000n,
  TIER_BASIC: 1n,
  TIER_PRO: 2n,
  TIER_ENTERPRISE: 3n,
  tierDurations: new Map<bigint, bigint>([
    [1n, 4320n],
    [2n, 12960n],
    [3n, 52560n],
  ]),

  isAdmin(caller: string) {
    return caller === this.admin;
  },

  isMinter(caller: string) {
    return caller === this.minter;
  },

  setPaused(caller: string, pause: boolean) {
    if (!this.isAdmin(caller)) return { error: 100 };
    this.paused = pause;
    return { value: pause };
  },

  setMinter(caller: string, newMinter: string) {
    if (!this.isAdmin(caller)) return { error: 100 };
    if (newMinter === "SP000000000000000000002Q6VF78") return { error: 105 };
    this.minter = newMinter;
    return { value: true };
  },

  subscribeMint(caller: string, recipient: string, tier: bigint, amount: bigint, autoRenew: boolean) {
    if (!this.isMinter(caller)) return { error: 100 };
    if (recipient === "SP000000000000000000002Q6VF78") return { error: 105 };
    if (amount <= 0n) return { error: 107 };
    if (!this.tierDurations.has(tier)) return { error: 106 };
    if (this.subscriptions.has(recipient)) return { error: 108 };
    const duration = this.tierDurations.get(tier)!;
    this.balances.set(recipient, (this.balances.get(recipient) || 0n) + amount);
    this.subscriptions.set(recipient, {
      tier,
      startBlock: this.blockHeight,
      duration,
      autoRenew,
      active: true,
    });
    return { value: true };
  },

  transfer(caller: string, amount: bigint, sender: string, recipient: string) {
    if (this.paused) return { error: 104 };
    if (amount <= 0n) return { error: 107 };
    if (recipient === "SP000000000000000000002Q6VF78") return { error: 105 };
    const allowanceKey = `${sender}-${caller}`;
    const allowance = this.allowances.get(allowanceKey) || 0n;
    if (caller !== sender && allowance < amount) return { error: 100 };
    const bal = this.balances.get(sender) || 0n;
    if (bal < amount) return { error: 101 };
    this.balances.set(sender, bal - amount);
    this.balances.set(recipient, (this.balances.get(recipient) || 0n) + amount);
    if (caller !== sender) {
      this.allowances.set(allowanceKey, allowance - amount);
    }
    return { value: true };
  },

  approve(caller: string, spender: string, amount: bigint) {
    if (this.paused) return { error: 104 };
    if (amount <= 0n) return { error: 107 };
    if (spender === "SP000000000000000000002Q6VF78") return { error: 105 };
    const key = `${caller}-${spender}`;
    this.allowances.set(key, amount);
    return { value: true };
  },

  cancelBurn(caller: string) {
    if (this.paused) return { error: 104 };
    const sub = this.subscriptions.get(caller);
    if (!sub || !sub.active) return { error: 103 };
    const balance = this.balances.get(caller) || 0n;
    if (balance <= 0n) return { error: 101 };
    const usedBlocks = this.blockHeight - sub.startBlock;
    const refundAmount = (balance * (sub.duration - usedBlocks)) / sub.duration;
    this.balances.set(caller, 0n);
    sub.active = false;
    return { value: refundAmount };
  },

  renew(caller: string, user: string) {
    if (this.paused) return { error: 104 };
    if (user === "SP000000000000000000002Q6VF78") return { error: 105 };
    const sub = this.subscriptions.get(user);
    if (!sub) return { error: 103 };
    if (sub.active) return { error: 109 };
    if (caller !== user && !sub.autoRenew) return { error: 109 };
    const balance = this.balances.get(user) || 0n;
    if (balance <= 0n) return { error: 101 };
    sub.startBlock = this.blockHeight;
    sub.active = true;
    return { value: true };
  },

  toggleAutoRenew(caller: string, enable: boolean) {
    if (this.paused) return { error: 104 };
    const sub = this.subscriptions.get(caller);
    if (!sub) return { error: 103 };
    sub.autoRenew = enable;
    return { value: true };
  },

  emergencyBurn(caller: string, user: string, amount: bigint) {
    if (!this.isAdmin(caller)) return { error: 100 };
    if (user === "SP000000000000000000002Q6VF78") return { error: 105 };
    if (amount <= 0n) return { error: 107 };
    const balance = this.balances.get(user) || 0n;
    if (balance < amount) return { error: 101 };
    this.balances.set(user, balance - amount);
    return { value: true };
  },

  getBalance(user: string): bigint {
    return this.balances.get(user) || 0n;
  },

  isActive(user: string): boolean {
    const sub = this.subscriptions.get(user);
    return !!sub && sub.active && this.blockHeight <= (sub.startBlock + sub.duration);
  },
};

describe("ChainSaaS Subscription Token", () => {
  beforeEach(() => {
    mockContract.admin = "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM";
    mockContract.minter = "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM";
    mockContract.paused = false;
    mockContract.balances = new Map();
    mockContract.allowances = new Map();
    mockContract.subscriptions = new Map();
    mockContract.blockHeight = 10000n;
  });

  it("should allow admin to set minter", () => {
    const result = mockContract.setMinter(mockContract.admin, "ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG");
    expect(result).toEqual({ value: true });
    expect(mockContract.minter).toBe("ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG");
  });

  it("should prevent setting minter to zero address", () => {
    const result = mockContract.setMinter(mockContract.admin, "SP000000000000000000002Q6VF78");
    expect(result).toEqual({ error: 105 });
  });

  it("should mint subscription tokens for a user", () => {
    const recipient = "ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG";
    const result = mockContract.subscribeMint(mockContract.minter, recipient, 1n, 1000n, true);
    expect(result).toEqual({ value: true });
    expect(mockContract.getBalance(recipient)).toBe(1000n);
    const sub = mockContract.subscriptions.get(recipient);
    expect(sub?.tier).toBe(1n);
    expect(sub?.autoRenew).toBe(true);
    expect(sub?.active).toBe(true);
  });

  it("should prevent minting with invalid tier", () => {
    const result = mockContract.subscribeMint(mockContract.minter, "ST2CY5...", 4n, 1000n, true);
    expect(result).toEqual({ error: 106 });
  });

  it("should prevent minting with zero amount", () => {
    const result = mockContract.subscribeMint(mockContract.minter, "ST2CY5...", 1n, 0n, true);
    expect(result).toEqual({ error: 107 });
  });

  it("should transfer tokens", () => {
    const sender = "ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG";
    const recipient = "ST3NBRSFKX28FQ2ZJ1MAKX58HKHSDGNV5N7R21XCP";
    mockContract.subscribeMint(mockContract.minter, sender, 1n, 500n, false);
    const result = mockContract.transfer(sender, 200n, sender, recipient);
    expect(result).toEqual({ value: true });
    expect(mockContract.getBalance(sender)).toBe(300n);
    expect(mockContract.getBalance(recipient)).toBe(200n);
  });

  it("should prevent transfer with zero amount", () => {
    const sender = "ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG";
    const recipient = "ST3NBRSFKX28FQ2ZJ1MAKX58HKHSDGNV5N7R21XCP";
    mockContract.subscribeMint(mockContract.minter, sender, 1n, 500n, false);
    const result = mockContract.transfer(sender, 0n, sender, recipient);
    expect(result).toEqual({ error: 107 });
  });

  it("should allow approved transfers", () => {
    const owner = "ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG";
    const spender = "ST3NBRSFKX28FQ2ZJ1MAKX58HKHSDGNV5N7R21XCP";
    const recipient = "ST4ABCDEF1234567890XYZ";
    mockContract.subscribeMint(mockContract.minter, owner, 1n, 500n, false);
    mockContract.approve(owner, spender, 300n);
    const result = mockContract.transfer(spender, 200n, owner, recipient);
    expect(result).toEqual({ value: true });
    expect(mockContract.getBalance(owner)).toBe(300n);
    expect(mockContract.getBalance(recipient)).toBe(200n);
    const allowanceKey = `${owner}-${spender}`;
    expect(mockContract.allowances.get(allowanceKey)).toBe(100n);
  });

  it("should cancel and burn tokens with prorated refund calculation", () => {
    const user = "ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG";
    mockContract.subscribeMint(mockContract.minter, user, 1n, 1000n, false);
    mockContract.blockHeight += 2160n; // Half duration for basic tier
    const result = mockContract.cancelBurn(user);
    expect(result).toEqual({ value: 500n }); // Half refund
    expect(mockContract.getBalance(user)).toBe(0n);
    const sub = mockContract.subscriptions.get(user);
    expect(sub?.active).toBe(false);
  });

  it("should toggle auto-renew", () => {
    const user = "ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG";
    mockContract.subscribeMint(mockContract.minter, user, 1n, 1000n, false);
    const result = mockContract.toggleAutoRenew(user, true);
    expect(result).toEqual({ value: true });
    const sub = mockContract.subscriptions.get(user);
    expect(sub?.autoRenew).toBe(true);
  });

  it("should allow emergency burn by admin", () => {
    const user = "ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG";
    mockContract.subscribeMint(mockContract.minter, user, 1n, 1000n, false);
    const result = mockContract.emergencyBurn(mockContract.admin, user, 500n);
    expect(result).toEqual({ value: true });
    expect(mockContract.getBalance(user)).toBe(500n);
  });

  it("should prevent emergency burn with zero amount", () => {
    const user = "ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG";
    mockContract.subscribeMint(mockContract.minter, user, 1n, 1000n, false);
    const result = mockContract.emergencyBurn(mockContract.admin, user, 0n);
    expect(result).toEqual({ error: 107 });
  });

  it("should not allow actions when paused", () => {
    mockContract.setPaused(mockContract.admin, true);
    const result = mockContract.transfer("ST2CY5...", 10n, "ST2CY5...", "ST3NB...");
    expect(result).toEqual({ error: 104 });
  });
});