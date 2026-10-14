import { createCoinbaseWalletSDK } from '@coinbase/wallet-sdk';
import { network, type Provider } from './chain';

export function coinbaseProvider(mobile: boolean): Provider {
  return createCoinbaseWalletSDK({
    appName: 'Perkshire IMDway',
    appLogoUrl: new URL('./logo-512.png', document.baseURI).href,
    appChainIds: [network.chainId],
    preference: { options: mobile ? 'smartWalletOnly' : 'all' }
  }).getProvider() as Provider;
}
