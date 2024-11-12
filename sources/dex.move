module kanari_network::dex {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};

    // Error codes
    const E_INSUFFICIENT_LIQUIDITY: u64 = 1;
    const E_INVALID_FEE: u64 = 2;
    const E_ZERO_AMOUNT: u64 = 3;
    const E_INSUFFICIENT_LP_TOKENS: u64 = 4;

    // Fee constants (basis points)
    const FEE_LOW: u64 = 10;    // 0.1%
    const FEE_MED: u64 = 50;    // 0.5%
    const FEE_HIGH: u64 = 100;  // 1.0%
    const BASIS_POINTS: u64 = 10000;

    /// Liquidity pool holding two tokens
    public struct LiquidityPool<phantom X, phantom Y> has key {
        id: UID,
        balance_x: Balance<X>,
        balance_y: Balance<Y>,
        fee_bps: u64,
        lp_supply: u64
    }

    /// LP token representing pool share
    public struct LPToken<phantom X, phantom Y> has key {
        id: UID,
        amount: u64
    }

    // Create a new liquidity pool
    public fun create_pool<X, Y>(
        fee_bps: u64,
        ctx: &mut TxContext
    ) {
        assert!(
            fee_bps == FEE_LOW || fee_bps == FEE_MED || fee_bps == FEE_HIGH,
            E_INVALID_FEE
        );

        let pool = LiquidityPool<X, Y> {
            id: object::new(ctx),
            balance_x: balance::zero(),
            balance_y: balance::zero(),
            fee_bps,
            lp_supply: 0
        };

        transfer::share_object(pool);
    }

    // Add liquidity to pool
    public fun add_liquidity<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        coin_x: Coin<X>,
        coin_y: Coin<Y>,
        ctx: &mut TxContext
    ): LPToken<X, Y> {
        let amount_x = coin::value(&coin_x);
        let amount_y = coin::value(&coin_y);
        
        assert!(amount_x > 0 && amount_y > 0, E_ZERO_AMOUNT);

        // Add tokens to pool
        balance::join(&mut pool.balance_x, coin::into_balance(coin_x));
        balance::join(&mut pool.balance_y, coin::into_balance(coin_y));

        // Mint LP tokens
        let lp_amount = if (pool.lp_supply == 0) {
            amount_x // Initial liquidity
        } else {
            // Proportional to contribution
            (amount_x * pool.lp_supply) / balance::value(&pool.balance_x)
        };

        pool.lp_supply = pool.lp_supply + lp_amount;

        // Create and return LP token
        LPToken<X, Y> {
            id: object::new(ctx),
            amount: lp_amount
        }
    }

    public fun remove_liquidity<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        lp_token: LPToken<X, Y>,
        ctx: &mut TxContext
    ): (Coin<X>, Coin<Y>) {
        let LPToken { id, amount: lp_amount } = lp_token;
        object::delete(id);
        
        // Calculate token amounts based on LP share
        let total_x = balance::value(&pool.balance_x);
        let total_y = balance::value(&pool.balance_y);
        
        let amount_x = (total_x * lp_amount) / pool.lp_supply;
        let amount_y = (total_y * lp_amount) / pool.lp_supply;
        
        assert!(amount_x > 0 && amount_y > 0, E_INSUFFICIENT_LP_TOKENS);

        // Update pool state
        pool.lp_supply = pool.lp_supply - lp_amount;

        // Withdraw tokens
        let coin_x = coin::from_balance(
            balance::split(&mut pool.balance_x, amount_x),
            ctx
        );
        let coin_y = coin::from_balance(
            balance::split(&mut pool.balance_y, amount_y),
            ctx
        );

        (coin_x, coin_y)
    }

    // Helper function for swap calculations
    fun calculate_swap_output(
        amount_in: u64,
        balance_in: u64,
        balance_out: u64,
        fee_bps: u64
    ): u64 {
        let amount_in_with_fee = amount_in * (BASIS_POINTS - fee_bps);
        let numerator = amount_in_with_fee * balance_out;
        let denominator = (balance_in * BASIS_POINTS) + amount_in_with_fee;
        numerator / denominator
    }

    // Swap X for Y
    public fun swap_x_to_y<X, Y>(
        pool: &mut LiquidityPool<X, Y>, 
        coin_in: Coin<X>,
        ctx: &mut TxContext
    ): Coin<Y> {
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, E_ZERO_AMOUNT);

        let amount_out = calculate_swap_output(
            amount_in,
            balance::value(&pool.balance_x),
            balance::value(&pool.balance_y),
            pool.fee_bps
        );

        assert!(amount_out > 0, E_INSUFFICIENT_LIQUIDITY);

        balance::join(&mut pool.balance_x, coin::into_balance(coin_in));
        coin::from_balance(balance::split(&mut pool.balance_y, amount_out), ctx)
    }

    // Swap Y for X  
    public fun swap_y_to_x<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        coin_in: Coin<Y>, 
        ctx: &mut TxContext
    ): Coin<X> {
        let amount_in = coin::value(&coin_in);
        assert!(amount_in > 0, E_ZERO_AMOUNT);

        let amount_out = calculate_swap_output(
            amount_in,
            balance::value(&pool.balance_y),
            balance::value(&pool.balance_x),
            pool.fee_bps
        );

        assert!(amount_out > 0, E_INSUFFICIENT_LIQUIDITY);

        balance::join(&mut pool.balance_y, coin::into_balance(coin_in));
        coin::from_balance(balance::split(&mut pool.balance_x, amount_out), ctx)
    }
}