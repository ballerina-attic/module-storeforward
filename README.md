# module-storeforward
The store forward connector provides guaranteed delivery in enterprise integration patterns.

### Compatibility

| Ballerina Language Version  | 
|:---------------------------:|
|  1.0.0                    |

##### Prerequisites
Download the ballerina [distribution](https://ballerinalang.org/downloads/).

### Pull and Install

#### Pull the Module
You can pull the store forward connector from Ballerina Central:
```ballerina
    $ ballerina pull wso2/storeforward
```

#### Install from Source
Alternatively, you can install store-forward connector from the source using the following instructions.

**Building the source**
1. Clone this repository using the following command:
    ```shell
        $ git clone https://github.com/wso2-ballerina/module-storeforward.git
    ```
2. Run this command from the `module-storeforward` root directory:
    ```shell
        $ ballerina compile storeforward
    ```

### Working with store forward connector

First, import the `wso2/storeforward` module into the Ballerina project. Requests receive to integration service should 
store in the queue using the `storeforward:Client`. Then `messageStore:MessageForwardingProcessor` is used to poll 
messages from the store and forward them reliably to HTTP endpoint.

#### Sample
##### Message Store
```ballerina
import ballerina/http;
import wso2/storeforward;

@http:ServiceConfig { basePath: "/stock-management" }
service stockQuote on new http:Listener(8080) {

    @http:ResourceConfig {
        methods: ["POST"],
        path: "/quotes"
    }
    resource function placeOrder(http:Caller caller, http:Request request) returns error? {
        // configure message store to publish stock orders
        storeforward:MessageStoreConfiguration storeConfig = {
            messageBroker: "ACTIVE_MQ",
            providerUrl: "tcp://localhost:61616",
            queueName: "stock_orders"
        };

        // initialize client to store the message
        storeforward:Client storeClient = check new storeforward:Client(storeConfig);
        var result = storeClient->store(request);

        // respond back to the caller based on the result
        if (result is error) {
            check caller->respond("Stock order placed failed.");
        } else {
            check caller->respond("Stock order placed successfully.");
        }
    }
}
```

##### Message Processor
```ballerina
import ballerina/http;
import ballerina/log;
import wso2/storeforward;

public function main(string... args) {
    // configure message store to consume stock orders
    storeforward:MessageStoreConfiguration storeConfig = {
            messageBroker: "ACTIVE_MQ",
            providerUrl: "tcp://localhost:61616",
            queueName: "stock_orders"
        };

    // configure processor to send the message to the backend every second
    storeforward:ForwardingProcessorConfiguration processorConfig = {
        storeConfig: storeConfig,
        HttpEndpointUrl: "http://localhost:9000/services/SimpleStockQuoteService",
        pollTimeConfig: 1000,
        retryInterval: 3000,
        maxRedeliveryAttempts: 5
    };

    // intialize and start processor to run peridically
    var stockOrderProcessor = new storeforward:MessageForwardingProcessor(processorConfig, handleResponse);
    if (stockOrderProcessor is error) {
        log:printError("Error while initializing message processor.", err = stockOrderProcessor);
        panic stockOrderProcessor;
    } else {
        var isStart = stockOrderProcessor. start();
        if (isStart is error) {
            panic isStart;
        } else {
            stockOrderProcessor.keepRunning();
        }
    }
}

// process the response received by stock quote service 
function handleResponse(http:Response response) {
    int statusCode = response.statusCode;
    if (statusCode == 200) {
        log:printInfo("Stock order persist sucessfully.");
    } else {
        log:printError("Error status code " + statusCode.toString() + " received from the stock quote service ");
    }
}
```

### How you can contribute

Clone the repository by running the following command
`git clone https://github.com/wso2-ballerina/module-storeforward.git`

As an open source project, we welcome contributions from the community. Check the [issue tracker](https://github.com/wso2-ballerina/module-googlespreadsheet/issues) for open issues that interest you. We look forward to receiving your contributions.
