// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SmartPropertyRental
 * @author DoubleFatZ (66026188 ศิวัฒน์ แก้วหนองสังข์, 66084733 ธนวัฒน์ ณรงค์วงศ์วัฒนา)
 * @notice โจทย์ที่ 4: ระบบจัดการสัญญาเช่าอสังหาริมทรัพย์และเงินประกัน (Smart Property Rental & Deposit Management)
 * บริษัท SmartLiving Property
 */
contract SmartPropertyRental {
    // =========================================================================
    // โครงสร้างข้อมูล (Data Structures & Enums)
    // =========================================================================

    enum AgreementStatus {
        Created,            // สร้างสัญญาแล้ว รอคู่สัญญายืนยัน
        Confirmed,          // ยืนยันครบทั้ง 2 ฝ่ายแล้ว รอผู้เช่าฝากเงินประกัน
        Active,             // วางเงินประกันแล้ว สัญญามีผลสมบูรณ์
        InspectionPending,  // สิ้นสุดสัญญา/ขอตรวจห้อง เจ้าของยื่นเสนอหักเงินประกัน รอผู้เช่าตอบรับ
        Disputed,           // ผู้เช่าคัดค้านการหักเงินประกัน ส่งต่อให้ Arbitrator ชี้ขาด
        Completed,          // คืน/จัดสรรเงินประกันเรียบร้อย สิ้นสุดสัญญาอย่างสมบูรณ์
        Cancelled           // ยกเลิกสัญญาก่อนเริ่มใช้งาน
    }

    struct Property {
        uint256 id;
        address payable owner;
        string roomName;
        string location;
        uint256 rentPerPeriod;     // ค่าเช่าต่องวด (Wei)
        uint256 securityDeposit;   // เงินประกันสัญญา (Wei)
        bool isAvailable;          // สถานะห้องว่างหรือไม่
        bool exists;
    }

    struct RentalAgreement {
        uint256 id;
        uint256 propertyId;
        address payable landlord;
        address payable tenant;
        uint256 startDate;
        uint256 endDate;
        uint256 rentPerPeriod;
        uint256 depositAmount;
        uint256 depositBalance;    // ยอดเงินประกันคงเหลือที่อยู่ใน Smart Contract
        string termsURI;           // เงื่อนไขสัญญาหรือลิงก์เอกสารข้อตกลง
        bool landlordConfirmed;    // เจ้าของห้องยืนยันด้วย Wallet
        bool tenantConfirmed;      // ผู้เช่ายืนยันด้วย Wallet
        AgreementStatus status;
        
        // การตรวจสภาพห้อง & ข้อพิพาท
        uint256 proposedDeduction; // ยอดหักเงินประกันที่เจ้าของเสนอ
        string deductionReason;    // เหตุผลการหักเงินประกัน
        string inspectionEvidence; // หลักฐานความเสียหาย (รูปภาพ/เอกสาร)
        string tenantDisputeReason;// เหตุผลที่ผู้เช่าคัดค้าน
        string arbitratorRuling;   // คำตัดสินของคนกลาง (Arbitrator)
        bool exists;
    }

    struct RentalPayment {
        uint256 installmentNumber;
        uint256 amount;
        uint256 timestamp;
        address payer;
    }

    // =========================================================================
    // ตัวแปรสถานะ (State Variables)
    // =========================================================================

    address public admin;          // SmartLiving Property Platform Admin
    address public arbitrator;     // ผู้มีอำนาจชี้ขาดข้อพิพาท (Arbitrator)

    uint256 public nextPropertyId;
    uint256 public nextAgreementId;

    mapping(uint256 => Property) public properties;
    mapping(uint256 => RentalAgreement) public agreements;
    mapping(uint256 => RentalPayment[]) private paymentHistories;

    // ระบบ Reentrancy Guard
    uint8 private _unlocked = 1;
    modifier nonReentrant() {
        require(_unlocked == 1, "REENTRANCY_GUARD");
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    // =========================================================================
    // Events
    // =========================================================================

    event PropertyRegistered(
        uint256 indexed propertyId,
        address indexed owner,
        string roomName,
        string location,
        uint256 rentPerPeriod,
        uint256 securityDeposit
    );

    event AgreementCreated(
        uint256 indexed agreementId,
        uint256 indexed propertyId,
        address indexed landlord,
        address tenant,
        uint256 startDate,
        uint256 endDate,
        uint256 rentPerPeriod,
        uint256 depositAmount
    );

    event AgreementConfirmed(
        uint256 indexed agreementId,
        address indexed confirmer,
        bool fullyConfirmed
    );

    event SecurityDeposited(
        uint256 indexed agreementId,
        address indexed tenant,
        uint256 amount
    );

    event RentPaid(
        uint256 indexed agreementId,
        address indexed tenant,
        address indexed landlord,
        uint256 installmentNumber,
        uint256 amount,
        uint256 timestamp
    );

    event InspectionSubmitted(
        uint256 indexed agreementId,
        uint256 deductionAmount,
        string reason,
        string evidence
    );

    event DepositSettled(
        uint256 indexed agreementId,
        uint256 refundToTenant,
        uint256 paidToLandlord,
        string note
    );

    event DisputeRaised(
        uint256 indexed agreementId,
        address indexed tenant,
        string disputeReason
    );

    event DisputeResolved(
        uint256 indexed agreementId,
        address indexed arbitrator,
        uint256 payToLandlord,
        uint256 refundToTenant,
        string rulingNotes
    );

    event ArbitratorUpdated(address indexed oldArbitrator, address indexed newArbitrator);

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyAdmin() {
        require(msg.sender == admin, "ONLY_ADMIN");
        _;
    }

    modifier onlyArbitrator() {
        require(msg.sender == arbitrator || msg.sender == admin, "ONLY_ARBITRATOR");
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor() {
        admin = msg.sender;
        arbitrator = msg.sender; // ค่าเริ่มต้นคือ Admin/Deployer เป็น Arbitrator
    }

    function setArbitrator(address _newArbitrator) external onlyAdmin {
        require(_newArbitrator != address(0), "INVALID_ADDRESS");
        emit ArbitratorUpdated(arbitrator, _newArbitrator);
        arbitrator = _newArbitrator;
    }

    // =========================================================================
    // 1. ลงทะเบียนทรัพย์สิน (Register Property)
    // =========================================================================
    function registerProperty(
        string calldata _roomName,
        string calldata _location,
        uint256 _rentPerPeriod,
        uint256 _securityDeposit
    ) external returns (uint256) {
        require(bytes(_roomName).length > 0, "ROOM_NAME_REQUIRED");
        require(_rentPerPeriod > 0, "INVALID_RENT_AMOUNT");
        require(_securityDeposit > 0, "INVALID_DEPOSIT_AMOUNT");

        uint256 propertyId = nextPropertyId++;
        properties[propertyId] = Property({
            id: propertyId,
            owner: payable(msg.sender),
            roomName: _roomName,
            location: _location,
            rentPerPeriod: _rentPerPeriod,
            securityDeposit: _securityDeposit,
            isAvailable: true,
            exists: true
        });

        emit PropertyRegistered(
            propertyId,
            msg.sender,
            _roomName,
            _location,
            _rentPerPeriod,
            _securityDeposit
        );

        return propertyId;
    }

    // =========================================================================
    // 2. สร้างสัญญาเช่า (Create Rental Agreement)
    // =========================================================================
    function createAgreement(
        uint256 _propertyId,
        address _tenant,
        uint256 _startDate,
        uint256 _endDate,
        string calldata _termsURI
    ) external returns (uint256) {
        Property storage prop = properties[_propertyId];
        require(prop.exists, "PROPERTY_NOT_FOUND");
        require(prop.owner == msg.sender, "ONLY_PROPERTY_OWNER");
        require(prop.isAvailable, "PROPERTY_NOT_AVAILABLE");
        require(_tenant != address(0), "INVALID_TENANT_ADDRESS");
        require(_tenant != msg.sender, "TENANT_CANNOT_BE_LANDLORD");
        require(_endDate > _startDate, "INVALID_DATE_RANGE");

        uint256 agreementId = nextAgreementId++;
        agreements[agreementId] = RentalAgreement({
            id: agreementId,
            propertyId: _propertyId,
            landlord: payable(msg.sender),
            tenant: payable(_tenant),
            startDate: _startDate,
            endDate: _endDate,
            rentPerPeriod: prop.rentPerPeriod,
            depositAmount: prop.securityDeposit,
            depositBalance: 0,
            termsURI: _termsURI,
            landlordConfirmed: true, // เจ้าของห้องเป็นผู้สร้าง ถือว่ายืนยันทันที
            tenantConfirmed: false,
            status: AgreementStatus.Created,
            proposedDeduction: 0,
            deductionReason: "",
            inspectionEvidence: "",
            tenantDisputeReason: "",
            arbitratorRuling: "",
            exists: true
        });

        emit AgreementCreated(
            agreementId,
            _propertyId,
            msg.sender,
            _tenant,
            _startDate,
            _endDate,
            prop.rentPerPeriod,
            prop.securityDeposit
        );

        return agreementId;
    }

    // =========================================================================
    // 3. ยืนยันสัญญา (Confirm Agreement)
    // =========================================================================
    function confirmAgreement(uint256 _agreementId) external {
        RentalAgreement storage ag = agreements[_agreementId];
        require(ag.exists, "AGREEMENT_NOT_FOUND");
        require(ag.status == AgreementStatus.Created, "INVALID_AGREEMENT_STATUS");
        require(msg.sender == ag.landlord || msg.sender == ag.tenant, "UNAUTHORIZED_PARTY");

        if (msg.sender == ag.landlord) {
            ag.landlordConfirmed = true;
        }
        if (msg.sender == ag.tenant) {
            ag.tenantConfirmed = true;
        }

        bool fullyConfirmed = ag.landlordConfirmed && ag.tenantConfirmed;
        if (fullyConfirmed) {
            ag.status = AgreementStatus.Confirmed;
        }

        emit AgreementConfirmed(_agreementId, msg.sender, fullyConfirmed);
    }

    // =========================================================================
    // 4. ฝากเงินประกัน (Deposit Security)
    // =========================================================================
    function depositSecurity(uint256 _agreementId) external payable nonReentrant {
        RentalAgreement storage ag = agreements[_agreementId];
        require(ag.exists, "AGREEMENT_NOT_FOUND");
        require(ag.status == AgreementStatus.Confirmed, "AGREEMENT_NOT_CONFIRMED");
        require(msg.sender == ag.tenant, "ONLY_TENANT_CAN_DEPOSIT");
        require(msg.value == ag.depositAmount, "INCORRECT_DEPOSIT_VALUE");

        ag.depositBalance = msg.value;
        ag.status = AgreementStatus.Active;

        // ล็อกห้องพักไม่ให้ผู้อื่นเช่าซ้ำ
        properties[ag.propertyId].isAvailable = false;

        emit SecurityDeposited(_agreementId, msg.sender, msg.value);
    }

    // =========================================================================
    // 5. บันทึกค่าเช่า (Record Rental Payment)
    // =========================================================================
    function payRent(uint256 _agreementId) external payable nonReentrant {
        RentalAgreement storage ag = agreements[_agreementId];
        require(ag.exists, "AGREEMENT_NOT_FOUND");
        require(ag.status == AgreementStatus.Active, "AGREEMENT_NOT_ACTIVE");
        require(msg.sender == ag.tenant, "ONLY_TENANT_CAN_PAY_RENT");
        require(msg.value == ag.rentPerPeriod, "INCORRECT_RENT_AMOUNT");

        uint256 installment = paymentHistories[_agreementId].length + 1;
        paymentHistories[_agreementId].push(RentalPayment({
            installmentNumber: installment,
            amount: msg.value,
            timestamp: block.timestamp,
            payer: msg.sender
        }));

        // โอนเงินค่าเช่าส่งตรงให้เจ้าของห้องทันที
        (bool success, ) = ag.landlord.call{value: msg.value}("");
        require(success, "RENT_TRANSFER_FAILED");

        emit RentPaid(
            _agreementId,
            msg.sender,
            ag.landlord,
            installment,
            msg.value,
            block.timestamp
        );
    }

    // =========================================================================
    // 6. ตรวจสภาพห้อง & คืนเงินประกัน (Submit Inspection & Refund Deposit)
    // =========================================================================
    function submitInspection(
        uint256 _agreementId,
        uint256 _deductionAmount,
        string calldata _deductionReason,
        string calldata _evidence
    ) external nonReentrant {
        RentalAgreement storage ag = agreements[_agreementId];
        require(ag.exists, "AGREEMENT_NOT_FOUND");
        require(ag.status == AgreementStatus.Active, "AGREEMENT_NOT_ACTIVE");
        require(msg.sender == ag.landlord, "ONLY_LANDLORD");
        require(_deductionAmount <= ag.depositBalance, "DEDUCTION_EXCEEDS_BALANCE");

        if (_deductionAmount > 0) {
            require(bytes(_deductionReason).length > 0, "REASON_REQUIRED_FOR_DEDUCTION");
        }

        ag.proposedDeduction = _deductionAmount;
        ag.deductionReason = _deductionReason;
        ag.inspectionEvidence = _evidence;

        // หากไม่มีการหักเงินเลย (สภาพห้องสมบูรณ์ 100%) คืนเงินประกันผู้เช่าทันที
        if (_deductionAmount == 0) {
            uint256 refundAmount = ag.depositBalance;
            ag.depositBalance = 0;
            ag.status = AgreementStatus.Completed;
            properties[ag.propertyId].isAvailable = true;

            (bool success, ) = ag.tenant.call{value: refundAmount}("");
            require(success, "REFUND_TRANSFER_FAILED");

            emit DepositSettled(_agreementId, refundAmount, 0, "Full refund: Room inspection passed without damage");
        } else {
            // หากมีความเสียหาย เข้าสู่สถานะรอผู้เช่าพิจารณายอมรับหรือคัดค้าน
            ag.status = AgreementStatus.InspectionPending;
            emit InspectionSubmitted(_agreementId, _deductionAmount, _deductionReason, _evidence);
        }
    }

    // ผู้เช่ายอมรับยอดหักเงินประกัน
    function acceptDeduction(uint256 _agreementId) external nonReentrant {
        RentalAgreement storage ag = agreements[_agreementId];
        require(ag.exists, "AGREEMENT_NOT_FOUND");
        require(ag.status == AgreementStatus.InspectionPending, "NOT_IN_INSPECTION_PENDING");
        require(msg.sender == ag.tenant, "ONLY_TENANT");

        uint256 deduction = ag.proposedDeduction;
        uint256 refund = ag.depositBalance - deduction;

        ag.depositBalance = 0;
        ag.status = AgreementStatus.Completed;
        properties[ag.propertyId].isAvailable = true;

        if (deduction > 0) {
            (bool s1, ) = ag.landlord.call{value: deduction}("");
            require(s1, "DEDUCTION_TRANSFER_FAILED");
        }

        if (refund > 0) {
            (bool s2, ) = ag.tenant.call{value: refund}("");
            require(s2, "REFUND_TRANSFER_FAILED");
        }

        emit DepositSettled(_agreementId, refund, deduction, "Tenant accepted proposed deduction");
    }

    // =========================================================================
    // 7. จัดการข้อโต้แย้ง (Rental Dispute)
    // =========================================================================
    function disputeInspection(uint256 _agreementId, string calldata _disputeReason) external {
        RentalAgreement storage ag = agreements[_agreementId];
        require(ag.exists, "AGREEMENT_NOT_FOUND");
        require(ag.status == AgreementStatus.InspectionPending, "NOT_IN_INSPECTION_PENDING");
        require(msg.sender == ag.tenant, "ONLY_TENANT");
        require(bytes(_disputeReason).length > 0, "DISPUTE_REASON_REQUIRED");

        ag.tenantDisputeReason = _disputeReason;
        ag.status = AgreementStatus.Disputed;

        emit DisputeRaised(_agreementId, msg.sender, _disputeReason);
    }

    // ผู้มีอำนาจ (Arbitrator) พิจารณาและบันทึกผลการตัดสินก่อนปล่อยเงิน
    function resolveDispute(
        uint256 _agreementId,
        uint256 _payToLandlord,
        uint256 _refundToTenant,
        string calldata _rulingNotes
    ) external onlyArbitrator nonReentrant {
        RentalAgreement storage ag = agreements[_agreementId];
        require(ag.exists, "AGREEMENT_NOT_FOUND");
        require(ag.status == AgreementStatus.Disputed, "AGREEMENT_NOT_DISPUTED");
        require(bytes(_rulingNotes).length > 0, "RULING_NOTES_REQUIRED");
        
        // กฎทางธุรกิจสำคัญ: ยอดรวมต้องเท่ากับเงินประกันคงเหลือพอดี และไม่สามารถคืนเงินเกินยอดคงเหลือได้
        require(_payToLandlord + _refundToTenant == ag.depositBalance, "TOTAL_MUST_EQUAL_DEPOSIT_BALANCE");

        ag.arbitratorRuling = _rulingNotes;
        ag.depositBalance = 0;
        ag.status = AgreementStatus.Completed;
        properties[ag.propertyId].isAvailable = true;

        if (_payToLandlord > 0) {
            (bool s1, ) = ag.landlord.call{value: _payToLandlord}("");
            require(s1, "LANDLORD_PAYMENT_FAILED");
        }

        if (_refundToTenant > 0) {
            (bool s2, ) = ag.tenant.call{value: _refundToTenant}("");
            require(s2, "TENANT_REFUND_FAILED");
        }

        emit DisputeResolved(
            _agreementId,
            msg.sender,
            _payToLandlord,
            _refundToTenant,
            _rulingNotes
        );
    }

    // =========================================================================
    // View & Getter Helpers
    // =========================================================================

    function getPaymentHistory(uint256 _agreementId) external view returns (RentalPayment[] memory) {
        return paymentHistories[_agreementId];
    }

    function getProperty(uint256 _propertyId) external view returns (Property memory) {
        return properties[_propertyId];
    }

    function getAgreement(uint256 _agreementId) external view returns (RentalAgreement memory) {
        return agreements[_agreementId];
    }

    function totalProperties() external view returns (uint256) {
        return nextPropertyId;
    }

    function totalAgreements() external view returns (uint256) {
        return nextAgreementId;
    }
}
