//! Faucet NEON token module.

use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::str::FromStr as _;

use actix_web::{http, HttpRequest};
use eyre::{eyre, Result};
use forwarded_header_value::ForwardedHeaderValue;
use tracing::{error, info};

use crate::{config, ethereum, id::ReqId, solana};

/// Represents packet of information needed for single airdrop operation.
#[derive(Debug, serde::Deserialize)]
pub struct Airdrop {
    /// Ethereum address of the recipient.
    wallet: String,
    /// Amount of a token to be received.
    amount: u64,
    /// Specifies amount in whole tokens (false, default) or in 10E-9 fractions (true).
    #[serde(default)]
    pub in_fractions: bool,
}

/// Processes the airdrop: sends needed transactions into Solana.
pub async fn airdrop(id: &ReqId, params: Airdrop) -> Result<()> {
    info!("{} Processing NEON {:?}...", id, params);

    if config::solana_account_seed_version() == 0 {
        config::load_neon_params().await?;
        check_token_account(id).await?;
    }

    let operator = config::solana_operator_keypair()
        .map_err(|e| eyre!("config::solana_operator_keypair: {:?}", e))?;
    let ether_address = ethereum::address_from_str(&params.wallet)
        .map_err(|e| eyre!("ethereum::address_from_str({}): {:?}", &params.wallet, e))?;
    solana::deposit_token(
        id,
        operator,
        ether_address,
        params.amount,
        params.in_fractions,
    )
    .await
    .map_err(|e| {
        eyre!(
            "solana::deposit_token(operator, {}): {:?}",
            ether_address,
            e
        )
    })?;
    Ok(())
}

/// Checks existence and balance of the operator's token account.
async fn check_token_account(id: &ReqId) -> Result<()> {
    use eyre::WrapErr as _;
    use solana_account_decoder::parse_token::UiTokenAmount;
    use solana_client::client_error::Result as ClientResult;
    use solana_client::rpc_client::RpcClient;
    use solana_sdk::pubkey::Pubkey;
    use solana_sdk::signature::Signer as _;
    use std::str::FromStr as _;

    let operator = config::solana_operator_keypair()
        .map_err(|e| eyre!("config::solana_operator_keypair: {:?}", e))?;
    let operator_pubkey = operator.pubkey();

    let token_mint_id = Pubkey::from_str(&config::solana_token_mint_id()).wrap_err_with(|| {
        eyre!(
            "config::solana_token_mint_id returns {}",
            &config::solana_token_mint_id(),
        )
    })?;

    let operator_token_pubkey = spl_associated_token_account::get_associated_token_address(
        &operator_pubkey,
        &token_mint_id,
    );

    info!("{} Token account: {}", id, operator_token_pubkey);
    let r = tokio::task::spawn_blocking(move || -> ClientResult<UiTokenAmount> {
        let client =
            RpcClient::new_with_commitment(config::solana_url(), config::solana_commitment());
        client.get_token_account_balance(&operator_token_pubkey)
    })
    .await??;

    let amount = r.ui_amount.unwrap_or_default();
    if amount <= f64::default() {
        return Err(eyre!(
            "Account {} has zero token balance {}",
            operator_token_pubkey,
            amount
        ));
    }

    Ok(())
}

#[derive(Debug)]
pub struct AirdropCapExceeded {
    requested: u64,
    limit: u64,
}

impl std::fmt::Display for AirdropCapExceeded {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "Requested value {} exceeds the limit {}", self.requested, self.limit)
    }
}

#[derive(Debug)]
pub enum AirdropLimiterError {
    BadRequest,
    CapExceeded(AirdropCapExceeded),
    BadConversion,
}

impl std::error::Error for AirdropLimiterError {}

impl std::fmt::Display for AirdropLimiterError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Self::BadRequest => write!(f, "Bad airdrop request"),
            Self::CapExceeded(err) => write!(f, "{}", err),
            Self::BadConversion => write!(f, "Failed to convert to fractional token value"),
        }
    }
}

pub struct AirdropLimiter {
    trusted_proxies: HashSet<IpAddr>,
    blacklist: HashSet<IpAddr>,
    // Token amounts in fractional units.
    ip_cache: HashMap<IpAddr, u64>,
    per_request_cap: u64,
    per_time_cap: u64,
}

impl AirdropLimiter {
    pub fn new(
        trusted_proxies: HashSet<IpAddr>,
        blacklist: HashSet<IpAddr>,
        per_request_cap: u64,
        per_time_cap: u64,
    ) -> Self {
        Self {
            trusted_proxies,
            blacklist,
            ip_cache: Default::default(),
            per_request_cap,
            per_time_cap,
        }
    }

    pub fn clear_cache(&mut self) {
        self.ip_cache.clear();
    }

    pub fn check_cache(
        &mut self,
        req: &HttpRequest,
        airdrop: &Airdrop
    ) -> Result<(), AirdropLimiterError> {
        let peer = self.get_peer(req)?;
        let request_amount = Self::parse_amount(airdrop)?;
        if request_amount > self.per_request_cap {
            error!("Airdrop request capped at {}", self.per_request_cap);
            return Err(AirdropLimiterError::CapExceeded(AirdropCapExceeded {
                requested: request_amount,
                limit: self.per_request_cap,
            }));
        }
        let total = self.ip_cache
            .entry(peer)
            .or_default();
            *total = total.saturating_add(request_amount);
        if *total > self.per_time_cap {
            error!("Airdrop requests capped at {}", self.per_time_cap);
            return Err(AirdropLimiterError::CapExceeded(AirdropCapExceeded {
                requested: *total,
                limit: self.per_time_cap,
            }));
        }
        Ok(())
    }

    fn get_peer(&self, req: &HttpRequest) -> Result<IpAddr, AirdropLimiterError> {
        let peer = req
            .peer_addr()
            .map(|socket| socket.ip())
            .ok_or_else(|| AirdropLimiterError::BadRequest)?;
        if !self.trusted_proxies.contains(&peer) {
            if self.blacklist.contains(&peer) {
                return Err(AirdropLimiterError::CapExceeded(AirdropCapExceeded {
                    requested: 0,
                    limit: 0,
                }));
            }
            return Ok(peer);
        }
        // If the peer is our known proxy, then we trust the forwarded headers if they exist.
        // See https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Forwarded
        let forwarded = match req.headers().get(http::header::FORWARDED) {
            Some(forwarded) => {
                let forwarded = forwarded
                    .to_str()
                    .map_err(|_| AirdropLimiterError::BadRequest)?;
                ForwardedHeaderValue::from_str(forwarded)
                    .map_err(|_| AirdropLimiterError::BadRequest)?
            },
            None => match req.headers().get("X-Forwarded-For") {
                Some(forwarded) => {
                    let forwarded = forwarded
                        .to_str()
                        .map_err(|_| AirdropLimiterError::BadRequest)?;
                    ForwardedHeaderValue::from_x_forwarded_for(forwarded)
                        .map_err(|_| AirdropLimiterError::BadRequest)?
                },
                None => {
                    return Ok(peer)
                },
            }
        };
        let peer = forwarded
            .proximate_forwarded_for_ip()
            .ok_or_else(|| AirdropLimiterError::BadRequest)?;
        if self.blacklist.contains(&peer) {
            return Err(AirdropLimiterError::CapExceeded(AirdropCapExceeded {
                requested: 0,
                limit: 0,
            }));
        }
        Ok(peer)
    }

    fn parse_amount(airdrop: &Airdrop) -> Result<u64, AirdropLimiterError> {
        let request_amount = if airdrop.in_fractions {
            airdrop.amount
        } else {
            solana::convert_whole_to_fractions(airdrop.amount)
                .map_err(|_| AirdropLimiterError::BadConversion)?
        };
        Ok(request_amount)
    }
}
