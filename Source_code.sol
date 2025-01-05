
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
contract ICE_Contract {

    // Struct to store transaction details
    struct Transaction {
        uint256 amount; // The total amount (including premuim it transfers)
        uint256 req; // The amount the client wants to exchange
        uint256 premium; // The amount of premium the client pays-- one may be tempted to calculate premuim amount as:  amount - req. However, this naive approach may not work if the amunt if premuim is decided on the fly based on up-to-date market information
        uint256 timestamp;
        uint256 set_approved; // This flag is used to make sure the server can set the value of approved_by_server only once
        uint256 votes; // It keeps the total votes (in favour of the client) provided by auditors
        uint256 auditors_counter; // It counts the number of auditors voted (so far)
        address server; // The address of the server with which the client wants to interact
        bytes32 transactionId;
        bytes32 evidence;// Provided by the client in the case of complaint
        bool pending; // To track if the transaction is pending
        bool approved_by_server;
        bool transferred; // It determines if the client's amount has already been transferred to the server 
        bool complaint_made; // It determines if a client has made a complaint about this transaction

    }

    struct Pending_transaction{
        address clientAddress;
        uint256 index; // The position of the transaction in the array: transactions...
        //... Given the index and a client's address one can find the infomration about that particular transaction     
    }

    struct Auditor_voting_rec{
        address client;
        bytes32 transactionId;
        bool voted;
    }

    mapping(address => Auditor_voting_rec[]) public auditor_votes;
    // Mapping from an address to an array of transactions
    mapping(address => Transaction[]) public transactions;
    mapping (address=> uint256) public riskFactor; // For the sake of simplicity, set the riskfactor to a valud between 1 and 10. 
    mapping (address=> uint256) public auditorsList; // A list of registered auditors
    mapping (address=> uint256) public serversList; // A list of registered resvers
    mapping(address => uint[])  public clientsPaidPremuim; // Keeps track of how many time and how much each client paid premuim
    mapping(address => uint256) public balances; // To track how much each address has sent

    uint256 public threshold; // It determines the maximum number of corrupt auditors
    uint256 public auditorCount; // Counter to track the number of registered auditors
    uint256 public min_number_of_auditors; // Determines the minumum number of auditors required to compile a complaint
    uint256 public serverCount; // Counter to track the number of registered servers
    uint256 public coverage; // This is in percent of the full transaction amount covered by the policy, e.g., 0.5-- we use integer rather than floting point to define it. In calculation we will use 
    // coverage/100
    uint256 public policy_duration; // For simplicity we have fixed the duration of the policy for all clients
    uint256 public delta; // The period within which a client can withdraw an amount it has transferred
    address public owner; // The address of the owner of the smart contract, i.e., the operator, who deploys it. 
    Pending_transaction[] public globalPendingTransactions;

    constructor(uint256 min_number_of_auditors_) {
        owner = msg.sender; // msg.sender is the address that deploys the contract
        min_number_of_auditors = min_number_of_auditors_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }

    function contributeCapital() public payable  {
        require(msg.value > 0, "Contribution must be greater than 0");
    }

    function setDuration(uint256 policy_duration_, uint256 delta_) public onlyOwner {
        policy_duration = policy_duration_;
        delta = delta_;
    }

    function setCoverage(uint256 coverage_) public onlyOwner {
        coverage = coverage_;
    }

    function setThreshold(uint256 threshold_) public onlyOwner {
        if((threshold_ * auditorCount)/100 <= auditorCount/3) {
            threshold = threshold_;
        }
    }

    function setAuditor(address auditor) public onlyOwner{
        if (auditorsList[auditor] == 0) {
            auditorCount++;
        }
        auditorsList[auditor] = 1;
    }

    function setServer(address server) public onlyOwner{
        if (serversList[server] == 0) {
            serverCount++;
        }
        serversList[server] = 1;
    }

    function setRiskFactor(address server, uint256 risk_factor) public onlyOwner {
        require(serversList[server] == 1 && risk_factor >= 1 && risk_factor <= 10, "Error: the server has not been registered");
        riskFactor[server] = risk_factor;
    }

    function getBalance() public view returns (uint256){
        return  address(this).balance;
    }

    function castVote(uint256 vote, address client_address, bytes32 transactionId_) internal {
        
        require(vote == 1 || vote == 0, "Invalid input-- The value of vote must be 0 or 1"); // Check if the vote's format is correct, i.e., it's 0 or 1
        require(auditorsList[msg.sender] == 1, "Invalid auditor-- The auditor must be registered"); // Check if the auditor has been registered    
        bool not_continu;
        bool not_continu_;
        // Check if the auditor has not already voted for this client's transaction-- otherwise do not continue
        for(uint256 j = 0; j < auditor_votes[msg.sender].length && !not_continu_; j++) {
            if(auditor_votes[msg.sender][j].client == client_address && 
            auditor_votes[msg.sender][j].transactionId == transactionId_ &&
            auditor_votes[msg.sender][j].voted == true) {
            not_continu_ = true;
            }
        }
        if(!not_continu_){
            // record the auditor's vote in the transaction
            for(uint256 i = 0; i < transactions[client_address].length && !not_continu; i++) {
                if(transactions[client_address][i].transactionId == transactionId_ && transactions[client_address][i].complaint_made == true) {
                    transactions[client_address][i].votes += 1;
                    transactions[client_address][i].auditors_counter += 1;
                    auditor_votes[msg.sender].push(Auditor_voting_rec({client: client_address, transactionId: transactionId_, voted : true})); // Record the auditor's vote in auditor_votes
                    not_continu = true;
                }
            }
        }
    }


    function calPremium(uint256 transactionValue, address server) public view returns(uint256) {
        // Scale factor to simulate decimal calculations (e.g., 1000 for 3 decimal places)
        uint256 scaleFactor = 1000000;
        uint256 riskAdjustment = riskFactor[server] * 30;
        // Adjust policy duration impact: cap the duration influence to avoid exponential growth
        uint256 durationAdjustment = (policy_duration < 3) ? policy_duration * 30 : policy_duration * 40; // Equivalent to `policy_duration * 0.01`
        uint256 temp = (transactionValue * riskAdjustment * durationAdjustment * coverage) / scaleFactor;
        if (temp == 0) {
            temp = 1;
        }
        return temp;
    }

    function extractVerdict(address client_address, uint256 index) public view returns (uint256){
        //bool not_continu;
        uint256 res = 0;
        require(transactions[client_address].length > 0, "Error: the client has made no transaction");
        uint256 temp = transactions[client_address][index].auditors_counter - (transactions[client_address][index].auditors_counter * threshold) / 100;
        if(transactions[client_address][index].votes >=  temp) {
            res = 1;
        }
        return res;
    }

    function addPremuim(address client, uint256 amount) internal{
        clientsPaidPremuim[client].push(amount);
    }

    function compRemAmount(uint256 coverage_, uint256 transaction_amount) public pure returns(uint256) {// in future we may need to change "pure" to something else
        return (coverage_ * transaction_amount) / 100;
    }

    function regComplaint(bytes32 evidence_, bytes32 transactionId_) public {
        bool not_continu;
        for(uint256 i = 0; i < transactions[msg.sender].length && !not_continu; i++) {
            if( (transactions[msg.sender][i].transactionId == transactionId_) && (transactions[msg.sender][i].complaint_made == false) ) {
                transactions[msg.sender][i].complaint_made = true;
                transactions[msg.sender][i].evidence = evidence_;
            }
        }
    }

    // The client needs to transfer a correct amount of coin via this function. Specifically, it needs to transfer amunt: req_ + premium (recall that this function is payable and the cleint can directly send coins when calling this function
    function sendTransaction (address server_, uint256 req_) public payable{ // for the sake of simplicity, we let "req" contain only the value the client wants to exchange 
        require(msg.value > 0, "You must send some Ether");
        // Check if (1) a sufficient amount has been transferred, (2) the client wants to interact with a registered server, or (3) the contract has enough budget to serve the client
        req_ = req_ * 1 ether;
        uint256 prem = calPremium(req_, server_);
        if( (msg.value < prem + req_) || (serversList[server_] != 1) || (checkBudget(req_, server_) == 0)) { 
            payable(msg.sender).transfer(msg.value); // If any of the above three conditions are not met, it refunds the client 
        }
        else {
            updatePendingTransaction();
            balances[msg.sender] += msg.value; // Update the client's balance
            // Creates a transaction (of type struct) for the payment the client made
            bytes32 transactionId = keccak256(abi.encodePacked(msg.sender, msg.value, block.number, block.timestamp));
            transactions[msg.sender].push(Transaction({amount: msg.value, req: req_, premium: prem, 
            transactionId: transactionId, timestamp: block.timestamp, pending: true, server: server_, 
            approved_by_server: false, set_approved: 0, votes: 0, transferred: false, complaint_made: false, evidence: 0x0, auditors_counter: 0})); // Store the transaction details in the mapping
            uint256 index_ = transactions[msg.sender].length - 1;
            globalPendingTransactions.push(Pending_transaction({clientAddress: msg.sender, index: index_}));// Adds the request to the pending transaction list.
        }
    }

    // Given an address of a client and index (i-th transaction made by the owner of address), it returns the transaction details
    function getTransactionByIndex(address address_, uint256 index) public view returns (Transaction memory) {
        require(index < transactions[address_].length, "Invalid index");
        return transactions[address_][index];
    }

    function updatePendingTransaction() public {
        uint256 currentTime = block.timestamp;
        // Iterate over the global pending transactions
        for (uint256 i = 0; i < globalPendingTransactions.length; i++) {
            //transactions[globalPendingTransactions[i].clientAddress];
            address address_ = globalPendingTransactions[i].clientAddress;
            uint256 size = transactions[address_].length;
            for (uint256 j = 0; j < size; j++) {
                if(currentTime - transactions[address_][j].timestamp > 365 * 24 * 60 * 60 * policy_duration) {
                    transactions[address_][j].pending = false;
                }
            }
        }
    }

    function getTotalPendingTransactionAmount()  internal view returns (uint256){
        uint256 totalPendingTransAmount = 0; 
        for (uint256 i = 0; i < globalPendingTransactions.length; i++) {          
            address address_ = globalPendingTransactions[i].clientAddress;
            uint256 index_ = globalPendingTransactions[i].index;
            if(transactions[address_][index_].pending == true) {
                totalPendingTransAmount += transactions[address_][index_].amount; 
            }
        }
        return totalPendingTransAmount;
    }

    function totalCompensasionAmount() internal view returns (uint256){
        uint256 val = getTotalPendingTransactionAmount();
        return (coverage/100) * val;
    }

    function checkBudget(uint256 transactionValue, address server) public view returns(uint256){
        uint256 res  = 1;
        uint256 premium = calPremium(transactionValue, server);
        uint256 compensation = compRemAmount(coverage, transactionValue);
        uint256 balance = address(this).balance;
        uint256 totalCompAmount = totalCompensasionAmount();
        if(balance + premium < compensation + totalCompAmount){
            res = 0;
        }
        return res;  
    }

    // Returns the amount amount_ to the caller, if it has previousely transferred that amount and it is within the refund time, delta. 
    function withdraw(uint256 amount_) public {
        bool continu = false;
        require(transactions[msg.sender].length > 0, "Invalid request"); // Check if the caller/client (i.e., msg.sender) has previously transferred any amount 
        for(uint256 i =0; i < transactions[msg.sender].length && !continu; i++) {
            if(transactions[msg.sender][i].amount == amount_) { // Check the amount stated matches the amount transferred
                if(delta > block.timestamp - transactions[msg.sender][i].timestamp){ // Check if it's still within the valid time period for withdrawal
                    payable(msg.sender).transfer(amount_);
                    continu = true; 
                    transactions[msg.sender][i].amount = 0;
                    transactions[msg.sender][i].pending = false;
                }
            }
        }
    }

    // It registers a result of verification of a client request. This function will successfully terminate only if it's called by a registered server (and must meet other conditions)
    function verRequest(address client_address, bytes32 transactionId_, bool val) public {
        bool continu = false;
        for(uint256 i = 0; i < transactions[client_address].length && !continu; i++) {
            // Check if (1) the provided transaction ID is valid, (2) the caller of this function (i.e., msg.sender) has been (registered and) mentioned in the transaction as the interacting server, and (3) 
            // the related value for the verification of request has not already been set.  
            if( (transactions[client_address][i].transactionId == transactionId_) && (transactions[client_address][i].server == msg.sender) && (transactions[client_address][i].set_approved == 0) ) {
                transactions[client_address][i].approved_by_server = val;
                transactions[client_address][i].set_approved = 1;
                continu = true;
            }
        }
    }

    // To transfer the amount from the smart contract to the server. We have inluded "client_address" as an argument to let anyone to call the function
    function transfer(address client_address, bytes32 transactionId_) public {
        require(transactions[client_address].length > 0, "Invalid request"); // Check if the caller/client (i.e., msg.sender) has previously transferred any amount 
        for(uint256 i = 0; i < transactions[client_address].length; i++) {
            if( (transactions[client_address][i].amount > 0) && 
            (transactions[client_address][i].transactionId == transactionId_) && 
            (delta < block.timestamp - transactions[client_address][i].timestamp) ) {
                // Refund the client if the server did not approve the client's request (and the server has already provided its response)
                if( (transactions[client_address][i].approved_by_server == false) && (transactions[client_address][i].set_approved == 1) ) {
                    payable(client_address).transfer(transactions[client_address][i].amount);
                    transactions[client_address][i].amount = 0;
                    transactions[client_address][i].pending = false;
                }
                // Trasnfer the req amount to the server and refund the client if the client paid extra (and if the server has approved client's request)
                else if( (transactions[client_address][i].approved_by_server == true) && 
                (transactions[client_address][i].set_approved == 1) &&
                (transactions[client_address][i].transferred == false) ) {
                    if(transactions[client_address][i].amount >= transactions[client_address][i].premium + transactions[client_address][i].req) {
                        payable(transactions[client_address][i].server).transfer(transactions[client_address][i].req); // Transfer the amount to the server
                        transactions[client_address][i].transferred = true; 
                        // Refund the client if it paid extra
                        if(transactions[client_address][i].amount > transactions[client_address][i].premium + transactions[client_address][i].req) {
                            uint256 refund_amount_to_client = transactions[client_address][i].amount - transactions[client_address][i].premium - transactions[client_address][i].req;
                            //refund_amount_to_client = refund_amount_to_client * 1 ether; 
                            payable(client_address).transfer(refund_amount_to_client); 
                        }
                    }
                }
            }
        }
    }

    function reimburse(uint256 vote, address client_address, bytes32 transactionId_) public {
        uint256 final_verdict;
        castVote(vote, client_address, transactionId_); // Cast each vote
        for(uint256 i = 0; i < transactions[client_address].length; i++) {
            // Each time an auditor votes, check if the total number of auditors voted for this specific transaction
            // reached the predefined threshold:min_number_of_auditors
            if(transactions[client_address][i].auditors_counter >= min_number_of_auditors){
                final_verdict = transactions[client_address][i].votes;
                uint256 temp = extractVerdict(client_address, i);
                if( (temp == 1) && (transactions[client_address][i].pending == true) ){
                    uint256 amount_ = compRemAmount(coverage, transactions[client_address][i].req);
                    transactions[client_address][i].pending = false;
                    payable(client_address).transfer(amount_);
                }
            }
        }
    }
}
