const { run } = require('hardhat')

async function verify (address, facet) {
  // const address = '0xfa7a3bb12848A7856Dd2769Cd763310096c053F1'; // deployed address
  // const facet = 'StakingFacet'; // name of facet
  await run('verifyFacet', {
    apikey: process.env.POLYGON_API_KEY,
    contract: address,
    facet
  })
}

// verify('0xfa7a3bb12848A7856Dd2769Cd763310096c053F1', 'StakingFacet');
exports.VerifyFacet = verify
