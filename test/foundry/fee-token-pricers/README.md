# Fee token pricer

When a chain is in AnyTrust mode transaction data is posted to an alternative data availability provider. However when in a chain is in rollup mode, transaction data is posted to the parent chain which the batch poster must pay for. When not using a custom fee token, the cost of posting this batch is relayed to the child chain where the batch poster will be reimbursed from user fees. However when the child chain is using a different fee token to the parent chain the data cost will paid in units of the parent chain fee token, and refunded in units of the child chain fee token. Therefore in order to refund the correct amount an exchange rate between the tokens must be used. This is what the fee token pricer provides.

## Implementation approach

When the batch poster posts data to the parent chain a batch spending report is produced. This batch spending report contains the gas price paid by the poster, and the amount of data in the batch. In order to reimburse the batch poster the correct amount in child chain fee tokens, the gas price in the batch spending report is scaled by the child to parent chain token price. In order to get this price the SequencerInbox calls `getExchangeRate` function on the fee token pricer at the time of creating a report. The chain owner can update the fee token pricer to a different implementation at any time.

Although the batch poster is receiving reimbursement in units of the child chain fee token rather than the parent chain units which they used to pay for gas, the value that they are reimbursed should be equal to the value that they paid.

## Fee token pricer types

A chain can choose different fee token pricer implementations to retrieve the exchange rate. Since the fees are reimbursed in child chain tokens but paid for in the parent chain tokens, there is an exchange rate risk. If the price deviates a lot before the batch poster converts the child chain currency back to parent chain currency, they may end up receiving less or more tokens than they originally paid for in gas. Below are some implementation types for the fee token pricer that have different tradeoffs for the batch poster and chain owner. Since the chain owner can change the fee token pricer at any time, the batch poster must always trust the chain owner not to do this for malicious purpose.

**Note.** There are some examples of these pricers in this repo, however none of these examples have been audited or properly tested, and are not ready for production use. These are example implementations to give an idea of the different options. Chain owners are expected to implement their own fee token pricer.

### Type 1 - Chain owner defined oracle

In this option the chain owner simply updated the exchange rate manually. This is the simplest option as it requires no external oracle or complicated implementation. However, unless the chain owner updates the price regularly it may diverge from the real price, causing under or over reimbursement. Additionally, unless a further safe guards are added, the batch poster must completely trust the chain owner to reimburse the correct amount. This option makes the most sense for a new chain, and where the batch poster and chain owner are the same entity or have a trusted relationship. The batch poster must also have an appetite for exchange risk, however this can be mitigated by artificially inflating the price to reduce the chance the batch poster is under reimbursed.

### Type 2 - External oracle

In this option an external oracle is used to fetch the exchange rate. Here the fee token pricer is responsible for ensuring the price is in the correct format and applying any safe guards that might be relevant. This option is easier to maintain that option 1. since an external party is reponsible for keep an up to date price on chain. However this places trust in the external party to keep the price up to date and to provide the correct price. To that end the pricer may apply some safe guards to avoid the price going too high or too low. This option also carries the same exchange risk as option 1, so a similar mitigation of marking up the price by a small amount might help to avoid under reimbursement

An example of this approach can be seen in [UniswapV2TwapPricer.sol](./uniswap-v2-twap/UniswapV2TwapPricer.sol).

### Type 3 - Exchange rate tracking

In this option it is assumed the batch poster has units of the child chain token and needs to trade them for units of the parent chain token to pay for the gas. They can record the exchange rate they used for this original trade in the fee token pricer, which will return that price when the batch poster requests an exchange rate to use. This removes the exchange risk problem, at the expense of a more complex accounting system in the fee token pricer. In this option the batch poster is implicitly a holder of the same number of child chain tokens at all times, they are not guaranteed any number of parent chain tokens.

The trust model in this approach is not that the batch poster is not forced to honestly report the correct price, but instead that the batch poster can be sure that they'll be refunded the correct amount.

An example of this approach can be seen in [TradeTracker.sol](./trade-tracker/TradeTracker.sol).

## Fee token pricer implementation considerations

When implementing a fee token pricer the trust assumptions of each of the involved parties must be considered.

- **Chain owner** - the chain owner is always trusted as they can change the fee token pricer at any time
- **Batch poster** - the batch poster is already trusted to provide valid batches that don't inflate data costs for users. In a type 3 fee token pricer they are additionally trusted to report the correct trade price
- **External parties** - in a type 2 fee token pricer an external party is trusted to provide up to date price information. If the price provided is too low the batch poster will be under-refunded, if the price provided is too high the batch poster will be over-refunded. To that end implementers should consider including price guards in their pricer to ensure the external can't provide values too far from the correct price. As an example, if the external party chose to set the price to max(uint) it would drain the child chain's gas pool, and dramatically raise the price for users. The chain owner would need to call admin functions to reset the sytem. This could be avoided by putting logic in the pricer to prevent extreme values.
