const fs = require("fs");
require('dotenv').config();
const { Location, ReturnType, CodeLanguage } = require('@chainlink/functions-toolkit');


const requestConfig = {
    source: fs.readFileSync("./functions/sources/alpacaBalance.js").toString(),
    codeLocation: Location.Inline,
    secrets: {
        alpacaKey: process.env.ALPACA_API_KEY ?? "",
        alpacaSecret: process.env.ALPACA_API_SECRET ?? ""
    },
    secretsLocation: Location.DONHosted,
    args: [],
    codeLanguage: CodeLanguage.JavaScript,
    expectedReturnType: ReturnType.uint256,
};

module.exports = requestConfig;
