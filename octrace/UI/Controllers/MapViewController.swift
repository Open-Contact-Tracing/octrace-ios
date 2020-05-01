import UIKit
import MapKit
import Alamofire

class MapViewController: UIViewController {
    
    private static let localLocationDistanceMeters = 3000
    private static let globalLocationDistanceMeters = 5000000
    
    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        
        df.dateStyle = .long
        df.timeStyle = .medium
        
        return df
    }()
    
    var rootViewController: RootViewController!
    
    private var mkContactPoints: [MKPointAnnotation: QrContactHealth] = [:]
    private var mkCountriesPoints: [MKPointAnnotation] = []
    private var mkUserPolylines: [MKPolyline] = []
    private var mkSickPolylines: [MKPolyline] = []
    private var tracks: [TrackingPoint] = []
    
    @IBOutlet weak var mapView: MKMapView!
    @IBOutlet weak var segmentedControl: UISegmentedControl!
    @IBOutlet weak var myLocationButton: UIButton!
    @IBOutlet weak var contactButton: UIButton!
    @IBOutlet weak var accuracyLabel: UILabel!
    @IBOutlet weak var indicator: UIActivityIndicatorView!
    
    @IBAction func segmentChanged(_ sender: Any) {
        // Need to do it asynchronously to enable the actual segment change ASAP
        DispatchQueue.main.async {
            if self.segmentedControl.selectedSegmentIndex == 0 {
                self.showLocalMap()
            } else {
                self.showGlobalMap()
            }
        }
    }
    
    @IBAction func zoomIn(_ sender: Any) {
        mapView.zoomLevel += 1
    }
    
    @IBAction func zoomOut(_ sender: Any) {
        mapView.zoomLevel -= 2
    }
    
    @IBAction func goToMyLocation(_ sender: Any) {
        guard let location = LocationManager.lastLocation else {
            return
        }
        
        goToLocation(location)
    }
    
    @IBAction func openBtLog(_ sender: Any) {
        let logsController = BtLogsViewController(nibName: "BtLogsViewController", bundle: nil)
        
        rootViewController.navigationController?.present(logsController, animated: true)
    }
    
    @IBAction func openDp3tLog(_ sender: Any) {
        let logsController = Dp3tLogsViewController(nibName: "Dp3tLogsViewController", bundle: nil)
        
        rootViewController.navigationController?.present(logsController, animated: true)
    }
    
    @IBAction func makeContact(_ sender: Any) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .denied:
                    self.showSettings("Need to enable notifications in Settings.")
                    
                case .notDetermined:
                    self.confirm("You need to enable notifications first, would you like to do it now?") {
                        UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .badge, .sound]) { _, _  in
                        }
                    }
                    
                default:
                    let linkController = QrLinkViewController(nibName: "QrLinkViewController", bundle: nil)
                    
                    self.rootViewController.navigationController?.present(linkController, animated: true)
                }
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        mapView.delegate = self
        mapView.showsUserLocation = true
        
        if #available(iOS 13.0, *) {
            indicator.style = .large
        }
        
        showLocalMap()
    }
    
    func updateUserTracks() {
        guard isLocal() else {
            return
        }
        
        print("Updating user tracks...")
        
        let polylines = makePolylines(TrackingManager.trackingData)
        
        print("Got \(polylines.count) user polylines.")
        
        mkUserPolylines.forEach(mapView.removeOverlay)
        mkUserPolylines = polylines.map { MKPolyline(coordinates: $0, count: $0.count) }
        mkUserPolylines.forEach(mapView.addOverlay)
    }
    
    func updateExtTracks() {
        guard isLocal() else {
            return
        }
        
        print("Updating external tracks...")
        
        var sickPolylines: [[CLLocationCoordinate2D]] = []
        
        TracksManager.tracks.forEach { track in
            let trackPolylines = makePolylines(track.points)
            sickPolylines.append(contentsOf: trackPolylines)
        }
        
        print("Got \(sickPolylines.count) sick polylines.")
        
        let now = Date.timeIntervalSinceReferenceDate
        
        mkSickPolylines.forEach(mapView.removeOverlay)
        mkSickPolylines = sickPolylines.map { MKPolyline(coordinates: $0, count: $0.count) }
        mkSickPolylines.forEach(mapView.addOverlay)
        
        let renderTime = Int(Date.timeIntervalSinceReferenceDate - now)
        
        print("Rendered \(sickPolylines.count) sick polylines in \(renderTime) seconds.")
        
        // So that user tracks are always above
        updateUserTracks()
    }
    
    private func makePolylines(_ points: [TrackingPoint]) -> [[CLLocationCoordinate2D]] {
        var polylines: [[CLLocationCoordinate2D]] = []
        var lastPolyline: [CLLocationCoordinate2D] = []
        var lastTimestamp: Int64 = 0
        
        func addPolyline() {
            if lastPolyline.count == 1 {
                // Each polyline should have at least 2 points
                lastPolyline.append(lastPolyline.first!)
            }
            
            polylines.append(lastPolyline)
        }
        
        points.forEach { point in
            let timestamp = point.tst
            let coordinate = point.coordinate()
            
            if lastTimestamp == 0 {
                lastPolyline = [coordinate]
            } else if timestamp - lastTimestamp > TrackingManager.trackingIntervalMs * 2 {
                addPolyline()
                
                lastPolyline = [coordinate]
            } else {
                lastPolyline.append(coordinate)
            }
            
            lastTimestamp = timestamp
        }
        
        addPolyline()
        
        return polylines
    }
    
    private func showLocalMap() {
        indicator.hide()
        
        mkCountriesPoints.forEach(mapView.removeAnnotation)
        
        goToMyLocation(global: false)
        
        updateExtTracks()
        updateContacts()
    }
    
    private func showGlobalMap() {
        let countriesRequest = URLRequest(url: URL(string: "https://services.arcgis.com/5T5nSi527N4F7luB/arcgis/" +
            "rest/services/Cases_by_country_Plg_V3/FeatureServer/0/query?f=json&where=1%3D1&returnGeometry=false&" +
            "spatialRel=esriSpatialRelIntersects&outFields=*&orderByFields=cum_conf%20desc&resultOffset=0&" +
            "resultRecordCount=310&cacheHint=true")!)
        
        indicator.show()
        AF.request(countriesRequest,
                   interceptor: NetworkUtil.eternalRetry).responseDecodable(of: MapFeatureValue.self) { response in
                    if let value = response.value {
                        self.indicator.hide()
                        self.updateCountriesInfo(with: value.features)
                    } else if let error = response.error {
                        print(error.localizedDescription)
                    }
        }
        
        mkSickPolylines.forEach(mapView.removeOverlay)
        mkContactPoints.keys.forEach(mapView.removeAnnotation)
        
        goToMyLocation(global: true)
    }
    
    private func goToMyLocation(global: Bool) {
        LocationManager.registerCallback { location in
            self.goToLocation(location)
            
            let distance = global ?
                MapViewController.globalLocationDistanceMeters :
                MapViewController.localLocationDistanceMeters
            
            let region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: CLLocationDistance(exactly: distance)!,
                longitudinalMeters: CLLocationDistance(exactly: distance)!
            )
            
            self.mapView.setRegion(self.mapView.regionThatFits(region), animated: true)
            
            self.myLocationButton.isEnabled = true
        }
    }
    
    private func updateCountriesInfo(with features: [MapFeature]) {
        guard !isLocal() else {
            return
        }
        
        mkCountriesPoints.forEach(mapView.removeAnnotation)
        
        mkCountriesPoints = []
        
        features.forEach { feature in
            if let lat = feature.attributes.CENTER_LAT,
                let lng = feature.attributes.CENTER_LON {
                
                let annotation = MKPointAnnotation()
                
                annotation.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                annotation.title = "\(feature.attributes.ADM0_NAME): \(feature.attributes.cum_conf) cases," +
                "\(feature.attributes.cum_death) deaths"
                
                mkCountriesPoints.append(annotation)
            }
        }
        
        mkCountriesPoints.forEach(mapView.addAnnotation)
    }
    
    func updateContacts() {
        guard isLocal() else {
            return
        }
        
        mkContactPoints.keys.forEach(mapView.removeAnnotation)
        mkContactPoints.removeAll()
        
        QrContactsManager.contacts.forEach { contact in
            let annotation = MKPointAnnotation()
            
            annotation.coordinate = contact.contact.coordinate()
            annotation.title = "Contact @ \(MapViewController.dateFormatter.string(from: contact.contact.date()))"
            
            mkContactPoints[annotation] = contact
        }
        
        mkContactPoints.keys.forEach(mapView.addAnnotation)
    }
    
    func goToContact(_ contact: QrContact) {
        if !isLocal() {
            segmentedControl.selectedSegmentIndex = 0
        }
        
        goToLocation(CLLocation(latitude: contact.lat, longitude: contact.lng))
    }
    
    private func isLocal() -> Bool {
        return segmentedControl.selectedSegmentIndex == 0
    }
    
    private func goToLocation(_ location: CLLocation) {
        mapView.setCenter(location.coordinate, animated: true)
    }
}

extension MapViewController: MKMapViewDelegate {
    
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else {
            return MKOverlayRenderer()
        }
        
        let renderer = MKPolylineRenderer(polyline: polyline)
        
        renderer.lineWidth = 3.0
        
        if mkUserPolylines.contains(polyline) {
            renderer.strokeColor = UIColor.systemBlue
        } else if mkSickPolylines.contains(polyline) {
            renderer.strokeColor = UIColor.systemRed
        }
        
        return renderer
    }
    
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation is MKPointAnnotation else { return nil }
        var annotationView: MKAnnotationView?
        var identifier: String?
        
        if let contact = mkContactPoints[annotation as! MKPointAnnotation] {
            if contact.infected {
                identifier = "InfectedContactAnnotation"
            } else {
                identifier = "ContactAnnotation"
            }
            
            annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier!)
        } else {
            identifier = "CountryAnnotation"
            annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier!)
        }
        
        if annotationView == nil {
            let pinAnnotationView = MKPinAnnotationView(annotation: annotation, reuseIdentifier: identifier!)
            if identifier == "InfectedContactAnnotation" {
                pinAnnotationView.pinTintColor = UIColor.systemRed
            } else if identifier == "ContactAnnotation" {
                pinAnnotationView.pinTintColor = UIColor.systemBlue
            } else {
                pinAnnotationView.pinTintColor = UIColor.systemYellow
            }
            
            annotationView = pinAnnotationView
            annotationView!.canShowCallout = true
        } else {
            annotationView!.annotation = annotation
        }
        
        return annotationView
    }
    
}


extension MKMapView {
    
    var zoomLevel: Int {
        get {
            return Int(log2(360 * (Double(frame.size.width/256) / region.span.longitudeDelta)) + 1)
        }
        
        set (newZoomLevel) {
            setCenterCoordinate(coordinate: centerCoordinate, zoomLevel: newZoomLevel, animated: true)
        }
    }
    
    private func setCenterCoordinate(coordinate: CLLocationCoordinate2D, zoomLevel: Int, animated: Bool) {
        let span = MKCoordinateSpan(latitudeDelta: 0, longitudeDelta: 360 / pow(2, Double(zoomLevel)) *
            Double(self.frame.size.width) / 256)
        setRegion(MKCoordinateRegion(center: coordinate, span: span), animated: animated)
    }
    
}
